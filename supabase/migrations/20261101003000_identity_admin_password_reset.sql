-- cross-schema: approved (admin password reset revokes auth sessions, scrambles the old password, enqueues identity email and writes audit.audit_log)
-- A tenant admin can reset a staff member's password. The reset is tenant-scoped (tenant comes from
-- the API's resolved tenant, re-checked here against the caller's memberships), refuses platform
-- admins and the caller's own account, is rate limited, revokes every session of the target, makes
-- the old password unusable, and emails a single-use link. The raw link token lives only on
-- identity.pending_emails until the worker sends it; this table keeps a SHA-256 hash.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ----------------------------------------------------------------- reset table ----
create table identity.password_resets (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references identity.tenants (id) on delete restrict,
  membership_id uuid not null references identity.memberships (id) on delete restrict,
  user_id       uuid not null,
  token_hash    bytea not null,
  expires_on    timestamptz not null,
  consumed_on   timestamptz,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  constraint password_resets_hash check (octet_length(token_hash) = 32)
);
comment on table identity.password_resets is
  'Admin-issued password reset links (SHA-256 of the token only). Not readable by clients.';
create index password_resets_user_idx on identity.password_resets (user_id, created_on desc);
create index password_resets_actor_idx on identity.password_resets (created_by, created_on desc);
create unique index password_resets_token_idx on identity.password_resets (token_hash);

alter table identity.password_resets enable row level security;
revoke all on identity.password_resets from public, anon, authenticated;
grant all on identity.password_resets to service_role;
create trigger password_resets_audit_columns
  before insert or update on identity.password_resets
  for each row execute function audit.stamp_audit_columns();

-- ------------------------------------------------------- allow the template ----
alter table identity.pending_emails drop constraint pending_emails_template_key_valid;
alter table identity.pending_emails add constraint pending_emails_template_key_valid check (
  template_key in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code', 'password_reset'));

create or replace function messaging.guard_email_payload()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_keys text[];
begin
  if new.aggregate_type is distinct from 'email_message' then
    return new;
  end if;
  select coalesce(array_agg(k order by k), '{}') into v_keys from jsonb_object_keys(new.payload) k;
  if v_keys is distinct from array['pending_email_id', 'template_key']
     or new.payload ->> 'template_key' not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code', 'password_reset')
     or new.payload ->> 'pending_email_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or new.payload::text like '%@%' then
    raise exception 'email outbox payload may only carry pending_email_id and template_key' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.guard_email_payload() from public;

create or replace function identity.enqueue_email(
  p_tenant_id uuid,
  p_aggregate_id uuid,
  p_template_key text,
  p_recipient text,
  p_variables jsonb,
  p_invite_link_id uuid default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_recipient text := lower(btrim(coalesce(p_recipient, '')));
  v_outbox_tenant uuid := coalesce(p_tenant_id, '00000000-0000-0000-0000-000000000000');
begin
  if p_template_key not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code', 'password_reset') then
    raise exception 'unknown email template' using errcode = '22023';
  end if;
  if p_variables is null or jsonb_typeof(p_variables) <> 'object' then
    raise exception 'email variables must be an object' using errcode = '22023';
  end if;
  if v_recipient !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_recipient) > 254 then
    raise exception 'email recipient is not a valid address' using errcode = '22023';
  end if;

  insert into identity.pending_emails (tenant_id, aggregate_id, invite_link_id, template_key, recipient, variables)
  values (p_tenant_id, p_aggregate_id, p_invite_link_id, p_template_key, v_recipient, p_variables)
  returning id into v_id;

  perform messaging.enqueue(
    v_outbox_tenant,
    'email_message',
    p_aggregate_id,
    'email.' || p_template_key,
    jsonb_build_object('pending_email_id', v_id, 'template_key', p_template_key));
  return v_id;
end;
$$;
revoke all on function identity.enqueue_email(uuid, uuid, text, text, jsonb, uuid) from public, anon, authenticated;

-- ------------------------------------------------- audit entry for admin events ----
-- Lets another schema's function append one row to audit.audit_log without reading or writing
-- the table directly (R3). The caller decides the content; never put secrets in p_data.
create or replace function audit.record_admin_event(
  p_tenant_id uuid, p_schema text, p_table text, p_record_id uuid, p_data jsonb, p_actor uuid)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into audit.audit_log (tenant_id, schema_name, table_name, record_id, action, old_data, new_data, changed_by)
  values (p_tenant_id, p_schema, p_table, p_record_id, 'INSERT', null, p_data, p_actor);
$$;
revoke all on function audit.record_admin_event(uuid, text, text, uuid, jsonb, uuid) from public, anon, authenticated;

-- -------------------------------------------------------------- admin reset ----
-- Errors: 42501 not an admin of p_tenant_id / member of another hospital / platform admin target,
-- P0002 unknown membership, 55000 own account, 54000 rate limited. Returns the link expiry.
create or replace function identity.admin_reset_member_password(p_tenant_id uuid, p_membership_id uuid)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_m identity.memberships%rowtype;
  v_email text;
  v_id uuid := gen_random_uuid();
  v_token text;
  v_expires timestamptz := pg_catalog.now() + interval '60 minutes';
  v_hospital text;
  v_crypto text;
  v_scrambled text;
begin
  if v_actor is null or p_tenant_id is null
     or p_tenant_id not in (select identity.current_tenant_ids())
     or not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can reset passwords' using errcode = '42501';
  end if;

  select m.* into v_m from identity.memberships m where m.id = p_membership_id;
  if v_m.id is null or v_m.is_deleted or v_m.status = 'invited' or v_m.user_id is null then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if v_m.tenant_id <> p_tenant_id then
    raise exception 'member belongs to another hospital' using errcode = '42501';
  end if;
  if v_m.user_id = v_actor then
    raise exception 'self_reset: use your own account settings to change your password' using errcode = '55000';
  end if;
  if exists (select 1 from identity.platform_admins pa where pa.user_id = v_m.user_id and not pa.is_deleted) then
    raise exception 'platform admins cannot be reset by a hospital admin' using errcode = '42501';
  end if;

  if (select count(*) from identity.password_resets r
       where r.user_id = v_m.user_id and r.created_on > pg_catalog.now() - interval '1 hour') >= 3
     or (select count(*) from identity.password_resets r
          where r.created_by = v_actor and r.created_on > pg_catalog.now() - interval '1 hour') >= 20 then
    raise exception 'too many password resets' using errcode = '54000';
  end if;

  select u.email into v_email from auth.users u where u.id = v_m.user_id for update;
  if v_email is null then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;

  -- Older links for this user stop working.
  update identity.password_resets r set consumed_on = pg_catalog.now()
   where r.user_id = v_m.user_id and r.consumed_on is null and not r.is_deleted;

  v_token := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
    gen_random_uuid()::text || gen_random_uuid()::text || pg_catalog.clock_timestamp()::text, 'UTF8')), 'hex');
  insert into identity.password_resets (id, tenant_id, membership_id, user_id, token_hash, expires_on)
  values (v_id, p_tenant_id, v_m.id, v_m.user_id, identity.invite_token_hash(v_token), v_expires);

  -- The old password stops working (replaced by a random bcrypt hash nobody knows) and the
  -- user must choose a new one after following the link.
  select n.nspname into v_crypto
    from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_crypto is null then
    raise exception 'pgcrypto is required' using errcode = '55000';
  end if;
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_crypto, v_crypto)
    into v_scrambled using pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex');
  update auth.users u
     set encrypted_password = v_scrambled,
         raw_user_meta_data = coalesce(u.raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('needs_password', true)
   where u.id = v_m.user_id;

  -- Sign the user out everywhere (refresh tokens hang off sessions; delete both explicitly).
  delete from auth.refresh_tokens t where t.user_id = v_m.user_id::text;
  delete from auth.sessions s where s.user_id = v_m.user_id;

  select t.name into v_hospital from identity.tenants t where t.id = p_tenant_id;
  perform identity.enqueue_email(
    p_tenant_id, v_id, 'password_reset', v_email,
    jsonb_build_object('token', v_token, 'hospitalName', v_hospital, 'expiresOn', v_expires));

  -- Who reset whom, and when. Never the token or a password.
  perform audit.record_admin_event(p_tenant_id, 'identity', 'password_resets', v_id,
    jsonb_build_object('event', 'admin_password_reset', 'target_user_id', v_m.user_id,
                       'membership_id', v_m.id, 'expires_on', v_expires),
    v_actor);
  return v_expires;
end;
$$;
revoke all on function identity.admin_reset_member_password(uuid, uuid) from public, anon;
grant execute on function identity.admin_reset_member_password(uuid, uuid) to authenticated, service_role, hms_svc_identity;

-- --------------------------------------------------------- consume the link ----
-- Returns the account email for a live link and burns it. Unknown, used or expired: P0002.
create or replace function identity.consume_password_reset(p_token text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_r identity.password_resets%rowtype;
  v_email text;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' then
    raise exception 'reset link not found, expired or already used' using errcode = 'P0002';
  end if;
  select r.* into v_r
    from identity.password_resets r
    join identity.memberships m on m.id = r.membership_id
    join identity.tenants t on t.id = r.tenant_id
   where r.token_hash = identity.invite_token_hash(lower(p_token))
     and r.consumed_on is null and r.expires_on > pg_catalog.now() and not r.is_deleted
     and not m.is_deleted and m.status <> 'invited'
     and t.status = 'active' and not t.is_deleted
   for update of r;
  if v_r.id is null then
    raise exception 'reset link not found, expired or already used' using errcode = 'P0002';
  end if;
  select u.email into v_email from auth.users u where u.id = v_r.user_id;
  if v_email is null then
    raise exception 'reset link not found, expired or already used' using errcode = 'P0002';
  end if;
  update identity.password_resets r set consumed_on = pg_catalog.now() where r.id = v_r.id;
  return v_email;
end;
$$;
revoke all on function identity.consume_password_reset(text) from public, anon, authenticated;
grant execute on function identity.consume_password_reset(text) to hms_mailer, service_role;
