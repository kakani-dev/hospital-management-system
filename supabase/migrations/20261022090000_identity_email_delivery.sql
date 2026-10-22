-- cross-schema: approved (identity enqueues messaging.outbox email events; mailer reads them back)
-- Product email for invite links and hospital sign-up. The outbox payload carries only
-- pending_email_id and template_key. Recipient, names, tokens and reasons stay in
-- identity.pending_emails and are redacted after a successful send.
--
-- Delivery role is hms_mailer, granted to hms_svc_identity only. hms_dispatcher stays with
-- hms_svc_scheduling. The legacy hms_api login is not granted hms_mailer or hms_dispatcher
-- (B1: the monolith dispatcher stays off). Gmail consumer accounts allow about 500 messages
-- a day; the worker enforces Email:Dispatcher:DailySendLimit (default 400) so Supabase Auth
-- mail on the same account has room. Swap IEmailSender later for a higher-volume provider.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- mailer role ----
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'hms_mailer') then
    create role hms_mailer nologin noinherit;
  end if;
end
$$;
comment on role hms_mailer is
  'Identity email worker. SET ROLE from hms_svc_identity only. Claims email_message outbox rows. Not granted to hms_api (B1).';
revoke hms_mailer from hms_api;
grant hms_mailer to hms_svc_identity;
grant usage on schema messaging to hms_mailer;
grant usage on schema identity to hms_mailer;

-- --------------------------------------------------------------- aggregate type ----
alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid
  check (aggregate_type in ('appointment', 'queue_entry', 'tenant', 'email_message'));

create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
    when 'tenant' then 'identity'
    when 'email_message' then 'identity'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

-- Payload guard: an email event cannot carry an address, name, token or reason.
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
     or new.payload ->> 'template_key' not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected')
     or new.payload ->> 'pending_email_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or new.payload::text like '%@%' then
    raise exception 'email outbox payload may only carry pending_email_id and template_key' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.guard_email_payload() from public;

drop trigger if exists outbox_guard_email_payload on messaging.outbox;
create trigger outbox_guard_email_payload
  before insert or update of payload, aggregate_type on messaging.outbox
  for each row execute function messaging.guard_email_payload();

-- ---------------------------------------------------------------- pending mail ----
-- Not tenant-owned: a sign-up acknowledgement exists before any hospital row.
-- No audit.log_row_change trigger: that log would keep the raw invite token forever.
create table identity.pending_emails (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references identity.tenants (id) on delete restrict,
  aggregate_id    uuid not null,
  invite_link_id  uuid references identity.invite_links (id) on delete restrict,
  template_key    text not null,
  recipient       text not null,
  variables       jsonb not null,
  redacted_on     timestamptz,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint pending_emails_template_key_valid check (
    template_key in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected')),
  constraint pending_emails_variables_object check (jsonb_typeof(variables) = 'object'),
  constraint pending_emails_variables_size check (pg_column_size(variables) <= 4000),
  constraint pending_emails_recipient_redacted check (
    (redacted_on is null and recipient ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(recipient) <= 254)
    or (redacted_on is not null and recipient = 'redacted@invalid.local' and variables = '{}'::jsonb))
);
comment on table identity.pending_emails is
  'Sensitive send material for one outbox email event. Redacted after send or when the invite is revoked, superseded or claimed. Not readable by clients.';
create index pending_emails_link_idx on identity.pending_emails (invite_link_id) where redacted_on is null and invite_link_id is not null;

alter table identity.pending_emails enable row level security;
revoke all on identity.pending_emails from public, anon, authenticated;
grant all on identity.pending_emails to service_role;
create trigger pending_emails_audit_columns
  before insert or update on identity.pending_emails
  for each row execute function audit.stamp_audit_columns();

-- ---------------------------------------------------------- idempotency ----
create table messaging.email_send_receipts (
  event_id   uuid primary key,
  tenant_id  uuid not null,
  sent_at    timestamptz not null default now()
);
comment on table messaging.email_send_receipts is
  'One row per outbox event_id that was handed to the SMTP sender. A retry that finds this row does not send again. No recipient or body.';
alter table messaging.email_send_receipts enable row level security;
revoke all on messaging.email_send_receipts from public, anon, authenticated, hms_dispatcher, hms_mailer;
grant all on messaging.email_send_receipts to service_role;
create index email_send_receipts_sent_idx on messaging.email_send_receipts (sent_at);

create or replace function messaging.email_already_sent(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from messaging.email_send_receipts r where r.event_id = p_event_id)
$$;
revoke all on function messaging.email_already_sent(uuid) from public, anon, authenticated;
grant execute on function messaging.email_already_sent(uuid) to hms_mailer, service_role;

create or replace function messaging.record_email_sent(p_event_id uuid, p_tenant_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into messaging.email_send_receipts (event_id, tenant_id)
  values (p_event_id, p_tenant_id)
  on conflict (event_id) do nothing;
  get diagnostics v_inserted = row_count;
  return v_inserted = 1;
end;
$$;
revoke all on function messaging.record_email_sent(uuid, uuid) from public, anon, authenticated;
grant execute on function messaging.record_email_sent(uuid, uuid) to hms_mailer, service_role;

create or replace function messaging.email_sends_today()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  -- UTC day. Gmail's consumer cap is about 500/day for the whole account, shared with Supabase Auth
  -- if that project uses the same mailbox. The worker stops claiming at its configured limit.
  select count(*)::integer
    from messaging.email_send_receipts r
   where r.sent_at >= (date_trunc('day', pg_catalog.now() at time zone 'UTC') at time zone 'UTC')
$$;
revoke all on function messaging.email_sends_today() from public, anon, authenticated;
grant execute on function messaging.email_sends_today() to hms_mailer, service_role;

-- ------------------------------------------------------- claim email rows ----
create or replace function messaging.claim_email_outbox(
  p_worker text, p_batch integer default 20, p_lease interval default '60 seconds')
returns setof messaging.outbox
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sources text[] := messaging.caller_sources();
begin
  if p_worker is null or length(btrim(p_worker)) = 0 or length(p_worker) > 200 then
    raise exception 'worker id required (<= 200 chars)' using errcode = '22023';
  end if;
  if p_batch is null or p_batch < 1 or p_batch > 500 then
    raise exception 'batch must be 1..500' using errcode = '22023';
  end if;
  if p_lease is null or p_lease <= interval '0' or p_lease > interval '1 hour' then
    raise exception 'lease must be > 0 and <= 1 hour' using errcode = '22023';
  end if;

  update messaging.outbox o
     set status = 'dead', claimed_by = null, claimed_until = null,
         last_error = coalesce(o.last_error, 'lease expired after max attempts')
   where o.aggregate_type = 'email_message'
     and o.status = 'processing' and o.claimed_until < now() and o.attempts >= 10
     and o.source_service = any (v_sources);

  return query
  with c as (
    select o.id
    from messaging.outbox o
    where o.aggregate_type = 'email_message'
      and o.source_service = any (v_sources)
      and ((o.status = 'pending' and o.available_at <= now())
        or (o.status = 'processing' and o.claimed_until < now()))
    order by o.id
    limit p_batch
    for update skip locked
  )
  update messaging.outbox o
     set status = 'processing',
         claimed_by = p_worker,
         claimed_until = now() + p_lease,
         attempts = o.attempts + 1
    from c
   where o.id = c.id
  returning o.*;
end;
$$;
revoke all on function messaging.claim_email_outbox(text, integer, interval) from public, anon, authenticated, hms_dispatcher;
grant execute on function messaging.claim_email_outbox(text, integer, interval) to hms_mailer, service_role;
-- Same source check the dispatcher uses. complete/fail call it as the function owner;
-- the mailer calls it directly to confirm which source it may consume.
grant execute on function messaging.caller_sources() to hms_mailer;

grant execute on function messaging.complete_outbox(bigint, text) to hms_mailer;
grant execute on function messaging.fail_outbox(bigint, text, text, interval) to hms_mailer;

-- ---------------------------------------------------- identity enqueue API ----
-- Platform mail (no hospital yet) uses the nil tenant id on the outbox row only.
-- identity.pending_emails.tenant_id stays null. The nil id is not an identity.tenants row.
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
  if p_template_key not in ('invite_link', 'signup_received', 'signup_approved', 'signup_rejected') then
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

  -- Payload is built here and nowhere else. Variables are not copied.
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

create or replace function identity.load_pending_email(p_id uuid)
returns table (template_key text, recipient text, variables jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  select p.template_key, p.recipient, p.variables
    from identity.pending_emails p
   where p.id = p_id and p.redacted_on is null and not p.is_deleted
$$;
revoke all on function identity.load_pending_email(uuid) from public, anon, authenticated;
grant execute on function identity.load_pending_email(uuid) to hms_mailer, service_role;

create or replace function identity.redact_pending_email(p_id uuid)
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
         redacted_on = coalesce(p.redacted_on, pg_catalog.now())
   where p.id = p_id and p.redacted_on is null;
end;
$$;
revoke all on function identity.redact_pending_email(uuid) from public, anon, authenticated;
grant execute on function identity.redact_pending_email(uuid) to hms_mailer, service_role;

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
end;
$$;
revoke all on function identity.suppress_emails_for_link(uuid) from public, anon, authenticated;

-- -------------------------------------------------------------- invite link ----
drop function identity.issue_invite_link(uuid, text, text, uuid, text, interval);

create function identity.issue_invite_link(
  p_tenant_id uuid, p_email text, p_role text, p_branch_id uuid, p_source text,
  p_ttl interval default interval '14 days', p_notify boolean default true)
returns table (id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_email text := lower(btrim(p_email));
  v_id uuid;
  v_expires timestamptz := pg_catalog.now() + p_ttl;
  v_hospital text;
  v_branch text;
  v_revoked uuid[] := '{}';
  v_old uuid;
begin
  with revoked as (
    update identity.invite_links l set status = 'revoked'
     where l.tenant_id = p_tenant_id and l.email = v_email and l.branch_id is not distinct from p_branch_id
       and l.status = 'pending' and not l.is_deleted
    returning l.id
  )
  select coalesce(array_agg(revoked.id), '{}'::uuid[]) into v_revoked from revoked;
  foreach v_old in array v_revoked loop
    perform identity.suppress_emails_for_link(v_old);
  end loop;

  insert into identity.invite_links (tenant_id, branch_id, email, role, token_hash, expires_on, source)
  values (p_tenant_id, p_branch_id, v_email, p_role, identity.invite_token_hash(v_token), v_expires, p_source)
  returning invite_links.id into v_id;

  if p_notify then
    select t.name into v_hospital from identity.tenants t where t.id = p_tenant_id;
    select b.name into v_branch from identity.branches b where b.id = p_branch_id;
    perform identity.enqueue_email(
      p_tenant_id, v_id, 'invite_link', v_email,
      jsonb_strip_nulls(jsonb_build_object(
        'hospitalName', v_hospital,
        'branchName', v_branch,
        'role', p_role,
        'token', v_token,
        'expiresOn', v_expires)),
      v_id);
  end if;

  return query select v_id, v_token, v_expires;
end;
$$;
revoke all on function identity.issue_invite_link(uuid, text, text, uuid, text, interval, boolean) from public, anon, authenticated;

create or replace function identity.revoke_invite_link(p_tenant_id uuid, p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can revoke invites' using errcode = '42501';
  end if;
  update identity.invite_links l set status = 'revoked'
   where l.id = p_link_id and l.tenant_id = p_tenant_id and l.status = 'pending' and not l.is_deleted;
  if not found then
    raise exception 'invite not found' using errcode = 'P0002';
  end if;
  perform identity.suppress_emails_for_link(p_link_id);
end;
$$;
revoke all on function identity.revoke_invite_link(uuid, uuid) from public, anon;
grant execute on function identity.revoke_invite_link(uuid, uuid) to authenticated;

create or replace function identity.claim_invite_link(p_token text)
returns table (tenant_id uuid, tenant_name text, role text, branch_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_l identity.invite_links%rowtype;
  v_m record;
  v_membership uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select l.* into v_l
  from identity.invite_links l
  join identity.tenants t on t.id = l.tenant_id
  where l.token_hash = identity.invite_token_hash(p_token)
    and l.status = 'pending' and l.expires_on > now() and not l.is_deleted
    and t.status = 'active' and not t.is_deleted
  for update of l;
  if v_l.id is null then
    raise exception 'invite not found, expired or already used' using errcode = 'P0002';
  end if;
  select lower(u.email) into v_email from auth.users u where u.id = v_uid;
  if v_email is distinct from v_l.email then
    raise exception 'invite_email_mismatch: this invite is for a different email address' using errcode = '42501';
  end if;

  select m.id, m.status, m.is_deleted into v_m
  from identity.memberships m
  where m.tenant_id = v_l.tenant_id and m.user_id = v_uid and m.branch_id is not distinct from v_l.branch_id
  order by m.is_deleted, m.created_on desc
  limit 1;

  insert into identity.user_profiles (id, email) values (v_uid, v_email) on conflict (id) do nothing;
  if v_m.id is null or v_m.is_deleted then
    insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
    values (v_l.tenant_id, v_uid, v_l.branch_id, v_l.role, 'active')
    returning id into v_membership;
  elsif v_m.status = 'invited' then
    perform identity.accept_membership(v_m.id);
    v_membership := v_m.id;
  elsif v_m.status = 'suspended' then
    raise exception 'Your membership in this hospital is suspended. Ask a hospital admin.' using errcode = '55000';
  else
    v_membership := v_m.id;
  end if;

  update identity.invite_links l
     set status = 'claimed', claimed_by = v_uid, claimed_on = now(), membership_id = v_membership
   where l.id = v_l.id;
  perform identity.suppress_emails_for_link(v_l.id);
  return query
    select v_l.tenant_id, t.name, m.role, m.branch_id
    from identity.memberships m join identity.tenants t on t.id = m.tenant_id
    where m.id = v_membership;
end;
$$;
revoke all on function identity.claim_invite_link(text) from public, anon;
grant execute on function identity.claim_invite_link(text) to authenticated;

-- ------------------------------------------------------- public sign-up ----
create or replace function identity.submit_tenant_signup(
  p_hospital_name text, p_time_zone text, p_contact_name text, p_contact_email text,
  p_phone text, p_city text, p_source_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_email text := lower(btrim(coalesce(p_contact_email, '')));
  v_name text := btrim(p_hospital_name);
  v_contact text := btrim(p_contact_name);
begin
  if not identity.is_valid_time_zone(p_time_zone) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', coalesce(p_time_zone, 'null') using errcode = '22023';
  end if;
  if p_source_hash is not null and (
       select count(*) from identity.tenant_signup_requests r
        where r.source_hash = p_source_hash and r.created_on > now() - interval '24 hours') >= 3 then
    raise exception 'rate_limited: too many hospital registrations from this source' using errcode = '54000';
  end if;
  if (select count(*) from identity.tenant_signup_requests r where r.status = 'pending' and not r.is_deleted) >= 200 then
    raise exception 'rate_limited: the registration queue is full' using errcode = '54000';
  end if;
  if exists (select 1 from identity.tenant_signup_requests r
              where lower(r.contact_email) = v_email and r.status = 'pending' and not r.is_deleted) then
    return null; -- same 202, no second acknowledgement email
  end if;

  insert into identity.tenant_signup_requests (hospital_name, time_zone, contact_name, contact_email, phone, city, source_hash)
  values (v_name, identity.canonical_time_zone(p_time_zone), v_contact, v_email,
          btrim(p_phone), btrim(p_city), p_source_hash)
  returning id into v_id;

  perform identity.enqueue_email(null, v_id, 'signup_received', v_email, jsonb_build_object(
    'hospitalName', v_name,
    'contactName', v_contact));
  return v_id;
end;
$$;
revoke all on function identity.submit_tenant_signup(text, text, text, text, text, text, text) from public;
grant execute on function identity.submit_tenant_signup(text, text, text, text, text, text, text) to anon, authenticated, service_role;

create or replace function identity.platform_approve_signup(p_request_id uuid, p_tenant_code text)
returns table (tenant_id uuid, invite_link_id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r identity.tenant_signup_requests%rowtype;
  v_tenant uuid;
  v_link record;
begin
  perform identity.require_platform_admin();
  select * into v_r from identity.tenant_signup_requests r where r.id = p_request_id and not r.is_deleted for update;
  if v_r.id is null then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'This request was already %.', v_r.status using errcode = '55000';
  end if;

  v_tenant := identity.create_tenant(p_tenant_code, v_r.hospital_name, v_r.time_zone, null);
  -- The approval email carries the first-admin link. Do not also send invite_link.
  select * into v_link from identity.issue_invite_link(
    v_tenant, v_r.contact_email, 'tenant_admin', null, 'signup_approval', interval '14 days', false);

  update identity.tenant_signup_requests r
     set status = 'approved', decided_by = auth.uid(), decided_on = now(), tenant_id = v_tenant, invite_link_id = v_link.id
   where r.id = v_r.id;

  perform identity.enqueue_email(v_tenant, v_r.id, 'signup_approved', v_r.contact_email, jsonb_build_object(
    'hospitalName', v_r.hospital_name,
    'contactName', v_r.contact_name,
    'role', 'tenant_admin',
    'token', v_link.token,
    'expiresOn', v_link.expires_on), v_link.id);

  return query select v_tenant, v_link.id, v_link.token, v_link.expires_on;
end;
$$;
revoke all on function identity.platform_approve_signup(uuid, text) from public, anon;
grant execute on function identity.platform_approve_signup(uuid, text) to authenticated;

create or replace function identity.platform_reject_signup(p_request_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r identity.tenant_signup_requests%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  perform identity.require_platform_admin();
  if length(v_reason) not between 3 and 500 then
    raise exception 'reason: give a reason of 3-500 characters' using errcode = '22023';
  end if;
  select * into v_r from identity.tenant_signup_requests r where r.id = p_request_id and not r.is_deleted for update;
  if v_r.id is null then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'This request was already %.', v_r.status using errcode = '55000';
  end if;
  update identity.tenant_signup_requests r
     set status = 'rejected', decision_reason = v_reason, decided_by = auth.uid(), decided_on = now()
   where r.id = p_request_id;
  perform identity.enqueue_email(null, v_r.id, 'signup_rejected', v_r.contact_email, jsonb_build_object(
    'hospitalName', v_r.hospital_name,
    'contactName', v_r.contact_name,
    'reason', v_reason));
end;
$$;
revoke all on function identity.platform_reject_signup(uuid, text) from public, anon;
grant execute on function identity.platform_reject_signup(uuid, text) to authenticated;
