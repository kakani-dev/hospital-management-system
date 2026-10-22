-- cross-schema: approved (sign-in codes enqueue identity email events; payload guard stays in messaging)
-- A brand-new invitee has no auth.users row. The invite page asks for a one-time code, which this
-- migration stores as a hash and emails through the identity outbox. The raw code never enters
-- messaging.outbox. Revoking or claiming the link consumes any code still outstanding.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------- allow the template ----
alter table identity.pending_emails drop constraint pending_emails_template_key_valid;
alter table identity.pending_emails add constraint pending_emails_template_key_valid check (
  template_key in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code'));

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
     or new.payload ->> 'template_key' not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code')
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
  if p_template_key not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected', 'sign_in_code') then
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

-- ------------------------------------------------------------------- the codes ----
create table identity.email_sign_in_codes (
  id              uuid primary key,
  tenant_id       uuid not null references identity.tenants (id) on delete restrict,
  invite_link_id  uuid not null references identity.invite_links (id) on delete restrict,
  code_hash       bytea not null,
  expires_on      timestamptz not null,
  consumed_on     timestamptz,
  failed_attempts integer not null default 0,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint email_sign_in_codes_attempts check (failed_attempts >= 0 and failed_attempts <= 5),
  constraint email_sign_in_codes_hash check (octet_length(code_hash) = 32)
);
comment on table identity.email_sign_in_codes is
  'SHA-256 of a 6-digit invite sign-in code. The raw code is emailed from pending_emails and redacted after send. Not readable by clients.';
create index email_sign_in_codes_link_idx on identity.email_sign_in_codes (invite_link_id) where consumed_on is null;

alter table identity.email_sign_in_codes enable row level security;
revoke all on identity.email_sign_in_codes from public, anon, authenticated;
grant all on identity.email_sign_in_codes to service_role;
create trigger email_sign_in_codes_audit_columns
  before insert or update on identity.email_sign_in_codes
  for each row execute function audit.stamp_audit_columns();

-- A dead invite must not still have a live code or an unsent message that contains one.
create or replace function identity.suppress_emails_for_link(p_link_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update identity.pending_emails p
     set recipient = 'redacted@invalid.local',
         variables = '{}'::jsonb,
         redacted_on = pg_catalog.now()
   where p.invite_link_id = p_link_id and p.redacted_on is null and not p.is_deleted;
  update identity.email_sign_in_codes c
     set consumed_on = pg_catalog.now()
   where c.invite_link_id = p_link_id and c.consumed_on is null and not c.is_deleted;
end;
$$;
revoke all on function identity.suppress_emails_for_link(uuid) from public, anon, authenticated;

-- Issues one code for a pending invite and queues sign_in_code. Returns only the expiry.
-- Granted to hms_mailer, not to anon (test 24 keeps the anon function list).
create or replace function identity.issue_invite_sign_in_code(p_token text)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_l identity.invite_links%rowtype;
  v_id uuid := gen_random_uuid();
  v_bytes bytea;
  v_n integer;
  v_code text;
  v_expires timestamptz := pg_catalog.now() + interval '10 minutes';
  v_hospital text;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' then
    raise exception 'invite not found, expired or already used' using errcode = 'P0002';
  end if;
  select l.* into v_l
    from identity.invite_links l
    join identity.tenants t on t.id = l.tenant_id
   where l.token_hash = identity.invite_token_hash(p_token)
     and l.status = 'pending' and l.expires_on > pg_catalog.now() and not l.is_deleted
     and t.status = 'active' and not t.is_deleted
   for update of l;
  if v_l.id is null then
    raise exception 'invite not found, expired or already used' using errcode = 'P0002';
  end if;
  if (select count(*) from identity.email_sign_in_codes c
       where c.invite_link_id = v_l.id and c.created_on > pg_catalog.now() - interval '1 hour' and not c.is_deleted) >= 5 then
    raise exception 'too many sign-in codes' using errcode = '54000';
  end if;

  update identity.email_sign_in_codes c
     set consumed_on = pg_catalog.now()
   where c.invite_link_id = v_l.id and c.consumed_on is null and not c.is_deleted;

  v_bytes := pg_catalog.sha256(pg_catalog.convert_to(gen_random_uuid()::text, 'UTF8'));
  v_n := pg_catalog.get_byte(v_bytes, 0) * 65536 + pg_catalog.get_byte(v_bytes, 1) * 256 + pg_catalog.get_byte(v_bytes, 2);
  v_code := pg_catalog.lpad((v_n % 1000000)::text, 6, '0');

  insert into identity.email_sign_in_codes (id, tenant_id, invite_link_id, code_hash, expires_on)
  values (v_id, v_l.tenant_id, v_l.id, identity.invite_token_hash(v_code || ':' || v_id::text), v_expires);

  select t.name into v_hospital from identity.tenants t where t.id = v_l.tenant_id;
  perform identity.enqueue_email(
    v_l.tenant_id, v_id, 'sign_in_code', v_l.email,
    jsonb_build_object('code', v_code, 'token', p_token, 'hospitalName', v_hospital, 'expiresOn', v_expires),
    v_l.id);
  return v_expires;
end;
$$;
revoke all on function identity.issue_invite_sign_in_code(text) from public, anon, authenticated;
grant execute on function identity.issue_invite_sign_in_code(text) to hms_mailer, service_role;

-- Checks the code and returns the invited email. A mismatch returns NULL (the attempt is
-- counted, and the fifth mismatch burns the code). A missing invite raises P0002. A code
-- that is the wrong shape, already used, or expired raises 42501 before any write.
create or replace function identity.consume_invite_sign_in_code(p_token text, p_code text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_l identity.invite_links%rowtype;
  v_code identity.email_sign_in_codes%rowtype;
  v_hash bytea;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' or p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'sign-in code is not valid' using errcode = '42501';
  end if;
  select l.* into v_l
    from identity.invite_links l
    join identity.tenants t on t.id = l.tenant_id
   where l.token_hash = identity.invite_token_hash(p_token)
     and l.status = 'pending' and l.expires_on > pg_catalog.now() and not l.is_deleted
     and t.status = 'active' and not t.is_deleted
   for update of l;
  if v_l.id is null then
    raise exception 'invite not found, expired or already used' using errcode = 'P0002';
  end if;

  select c.* into v_code
    from identity.email_sign_in_codes c
   where c.invite_link_id = v_l.id and c.consumed_on is null and c.expires_on > pg_catalog.now() and not c.is_deleted
   order by c.created_on desc
   limit 1
   for update;
  if v_code.id is null or v_code.failed_attempts >= 5 then
    raise exception 'sign-in code is not valid' using errcode = '42501';
  end if;

  v_hash := identity.invite_token_hash(p_code || ':' || v_code.id::text);
  if v_code.code_hash is distinct from v_hash then
    -- Return NULL instead of raising. A raise would roll this update back with the
    -- caller's exception handler, and the attempt counter would never stick.
    update identity.email_sign_in_codes c
       set failed_attempts = c.failed_attempts + 1,
           consumed_on = case when c.failed_attempts + 1 >= 5 then pg_catalog.now() else c.consumed_on end
     where c.id = v_code.id;
    return null;
  end if;

  update identity.email_sign_in_codes c
     set consumed_on = pg_catalog.now()
   where c.id = v_code.id;
  return v_l.email;
end;
$$;
revoke all on function identity.consume_invite_sign_in_code(text, text) from public, anon, authenticated;
grant execute on function identity.consume_invite_sign_in_code(text, text) to hms_mailer, service_role;
