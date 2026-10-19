-- =============================================================================
-- Level 1: platform console, approval-based hospital onboarding and invite links (identity only).
--
--   identity.tenant_signup_requests  public "Register your hospital" requests. NOT tenant-owned:
--                                    a request creates NO tenant, membership or access until a
--                                    platform admin approves it.
--   identity.invite_links            single-use, expiring, email-bound invite tokens (only a SHA-256
--                                    hash is stored). Issued on approval / direct tenant creation
--                                    (first tenant_admin) and by tenant admins for staff without an
--                                    account yet. Claiming requires the signed-in email to match.
--   identity.tenant_status_changes   suspend / reactivate history with the operator's reason.
--
-- Every platform_* function requires identity.is_platform_admin() (auth.uid() in
-- identity.platform_admins). Platform admins get NO implicit tenant access: no RLS policy or
-- tenancy helper consults is_platform_admin(), and the platform functions return only tenant
-- metadata and counts (never patient or appointment rows). Suspension needs no new checks:
-- current_tenant_ids / has_tenant_role / my_tenant_grant_v1 / set_active_context / my_memberships
-- already require tenants.status = 'active'.
--
-- Clients reach these tables only through the SECURITY DEFINER functions below (RLS on, no
-- policies, no table grants). Audit columns + audit log on every new table.
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------------ tables ----
create table identity.tenant_signup_requests (
  id              uuid primary key default gen_random_uuid(),
  hospital_name   text not null,
  time_zone       text not null,
  contact_name    text not null,
  contact_email   text not null,
  phone           text not null,
  city            text not null,
  status          text not null default 'pending',
  decision_reason text,
  decided_by      uuid,
  decided_on      timestamptz,
  tenant_id       uuid references identity.tenants (id) on delete restrict,
  invite_link_id  uuid,
  -- salted hash of the client address computed by the identity service (never the raw IP); used
  -- only for the per-source rate limit below
  source_hash     text,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint tenant_signup_hospital_name_len check (length(btrim(hospital_name)) between 2 and 120),
  constraint tenant_signup_contact_name_len check (length(btrim(contact_name)) between 2 and 120),
  constraint tenant_signup_email_format check (length(contact_email) <= 254 and contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint tenant_signup_phone_format check (phone ~ '^\+?[0-9][0-9 ()-]{6,19}$'),
  constraint tenant_signup_city_len check (length(btrim(city)) between 2 and 80),
  constraint tenant_signup_status_valid check (status in ('pending', 'approved', 'rejected')),
  constraint tenant_signup_reason_on_reject check (status <> 'rejected' or length(btrim(coalesce(decision_reason, ''))) >= 3),
  constraint tenant_signup_tenant_on_approve check (status <> 'approved' or tenant_id is not null),
  constraint tenant_signup_decision_stamped check (status = 'pending' or (decided_by is not null and decided_on is not null))
);
comment on table identity.tenant_signup_requests is
  'Public hospital registration requests (no auth). Grant nothing until a platform admin approves (identity.platform_approve_signup).';
create unique index tenant_signup_one_pending_per_email
  on identity.tenant_signup_requests (lower(contact_email)) where status = 'pending' and not is_deleted;
create index tenant_signup_source_recent_idx on identity.tenant_signup_requests (source_hash, created_on);
create index tenant_signup_status_idx on identity.tenant_signup_requests (status, created_on desc);

create table identity.invite_links (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references identity.tenants (id) on delete restrict,
  branch_id     uuid,
  email         text not null,
  role          text not null,
  token_hash    bytea not null,
  expires_on    timestamptz not null,
  status        text not null default 'pending',
  source        text not null,
  claimed_by    uuid references auth.users (id) on delete set null,
  claimed_on    timestamptz,
  membership_id uuid,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  constraint invite_links_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint invite_links_token_hash_key unique (token_hash),
  constraint invite_links_email_format check (length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+$'),
  constraint invite_links_role_valid check (role in (
    'tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer')),
  constraint invite_links_admin_tenant_wide check (role <> 'tenant_admin' or branch_id is null),
  constraint invite_links_status_valid check (status in ('pending', 'claimed', 'revoked')),
  constraint invite_links_source_valid check (source in ('signup_approval', 'platform', 'tenant_admin')),
  constraint invite_links_claim_stamped check (status <> 'claimed' or (claimed_by is not null and claimed_on is not null))
);
comment on table identity.invite_links is
  'Single-use email-bound invite tokens (SHA-256 hash only). Claimed by the invitee via identity.claim_invite_link().';
create index invite_links_tenant_idx on identity.invite_links (tenant_id, status, created_on desc);

alter table identity.tenant_signup_requests
  add constraint tenant_signup_invite_fk foreign key (invite_link_id) references identity.invite_links (id) on delete set null;

create table identity.tenant_status_changes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  from_status text not null,
  to_status   text not null,
  reason      text not null,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint tenant_status_changes_reason_len check (length(btrim(reason)) between 3 and 500),
  constraint tenant_status_changes_status_valid check (to_status in ('active', 'suspended') and from_status <> to_status)
);
create index tenant_status_changes_tenant_idx on identity.tenant_status_changes (tenant_id, created_on desc);

do $$
declare
  t text;
begin
  foreach t in array array['tenant_signup_requests', 'invite_links', 'tenant_status_changes'] loop
    execute format('alter table identity.%I enable row level security', t);
    execute format('revoke all on identity.%I from public, anon, authenticated', t);
    execute format('grant all on identity.%I to service_role', t);
    execute format('create trigger %I before insert or update on identity.%I for each row execute function audit.stamp_audit_columns()', t || '_audit_columns', t);
    execute format('create trigger %I after insert or update or delete on identity.%I for each row execute function audit.log_row_change()', t || '_audit_log', t);
  end loop;
end
$$;

-- ----------------------------------------------------------------- helpers ----
create or replace function identity.require_platform_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not identity.is_platform_admin() then
    raise exception 'only platform admins may do this' using errcode = '42501';
  end if;
end;
$$;
revoke all on function identity.require_platform_admin() from public, anon, authenticated;

create or replace function identity.invite_token_hash(p_token text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.sha256(pg_catalog.convert_to(coalesce(p_token, ''), 'UTF8'))
$$;
revoke all on function identity.invite_token_hash(text) from public, anon, authenticated;

-- Internal: issues a link (supersedes pending links for the same tenant/email/branch) and returns
-- the plain token ONCE. Callers check authorization first.
create or replace function identity.issue_invite_link(
  p_tenant_id uuid, p_email text, p_role text, p_branch_id uuid, p_source text, p_ttl interval default interval '14 days')
returns table (id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_email text := lower(btrim(p_email));
  v_id uuid;
  v_expires timestamptz := now() + p_ttl;
begin
  update identity.invite_links l set status = 'revoked'
   where l.tenant_id = p_tenant_id and l.email = v_email and l.branch_id is not distinct from p_branch_id
     and l.status = 'pending' and not l.is_deleted;
  insert into identity.invite_links (tenant_id, branch_id, email, role, token_hash, expires_on, source)
  values (p_tenant_id, p_branch_id, v_email, p_role, identity.invite_token_hash(v_token), v_expires, p_source)
  returning invite_links.id into v_id;
  return query select v_id, v_token, v_expires;
end;
$$;
revoke all on function identity.issue_invite_link(uuid, text, text, uuid, text, interval) from public, anon, authenticated;

-- ------------------------------------------------------- public: sign-up ----
-- anon needs USAGE on identity to call the two public functions below. It gets nothing else:
-- every other identity function is revoked from PUBLIC/anon and anon has no table privileges
-- (guardrail: supabase/tests/24_level1_platform_onboarding_test.sql pins the anon-callable set).
grant usage on schema identity to anon;

-- Anonymous. Returns the request id or NULL when an identical pending request (same email) exists
-- (the API answers 202 either way, so the endpoint cannot be used to probe who applied).
-- Abuse checks: at most 3 requests per source per 24 h and 200 pending requests overall
-- (54000 rate_limited -> 429). Field validation mirrors the CHECK constraints (22023 -> 400).
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
    return null;
  end if;

  insert into identity.tenant_signup_requests (hospital_name, time_zone, contact_name, contact_email, phone, city, source_hash)
  values (btrim(p_hospital_name), identity.canonical_time_zone(p_time_zone), btrim(p_contact_name), v_email,
          btrim(p_phone), btrim(p_city), p_source_hash)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function identity.submit_tenant_signup(text, text, text, text, text, text, text) from public;
grant execute on function identity.submit_tenant_signup(text, text, text, text, text, text, text) to anon, authenticated, service_role;

-- ------------------------------------------------ platform: sign-up queue ----
create or replace function identity.platform_list_signups(p_status text default null)
returns table (
  id uuid, hospital_name text, time_zone text, contact_name text, contact_email text, phone text, city text,
  status text, decision_reason text, decided_on timestamptz, tenant_id uuid, tenant_code text, created_on timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform identity.require_platform_admin();
  return query
    select r.id, r.hospital_name, r.time_zone, r.contact_name, r.contact_email, r.phone, r.city,
           r.status, r.decision_reason, r.decided_on, r.tenant_id, t.code, r.created_on
    from identity.tenant_signup_requests r
    left join identity.tenants t on t.id = r.tenant_id
    where not r.is_deleted and (p_status is null or r.status = p_status)
    order by (r.status = 'pending') desc, r.created_on desc
    limit 500;
end;
$$;
revoke all on function identity.platform_list_signups(text) from public, anon;
grant execute on function identity.platform_list_signups(text) to authenticated;

-- Approve: create the tenant with the requested zone (identity.create_tenant: default branch
-- inherits it) and issue the first-admin invite link. No membership exists until the contact
-- claims the link while signed in with that email.
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
  select * into v_link from identity.issue_invite_link(v_tenant, v_r.contact_email, 'tenant_admin', null, 'signup_approval');

  update identity.tenant_signup_requests r
     set status = 'approved', decided_by = auth.uid(), decided_on = now(), tenant_id = v_tenant, invite_link_id = v_link.id
   where r.id = v_r.id;
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
  v_status text;
begin
  perform identity.require_platform_admin();
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'reason: give a reason of 3-500 characters' using errcode = '22023';
  end if;
  select r.status into v_status from identity.tenant_signup_requests r where r.id = p_request_id and not r.is_deleted for update;
  if v_status is null then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_status <> 'pending' then
    raise exception 'This request was already %.', v_status using errcode = '55000';
  end if;
  update identity.tenant_signup_requests r
     set status = 'rejected', decision_reason = btrim(p_reason), decided_by = auth.uid(), decided_on = now()
   where r.id = p_request_id;
end;
$$;
revoke all on function identity.platform_reject_signup(uuid, text) from public, anon;
grant execute on function identity.platform_reject_signup(uuid, text) to authenticated;

-- ---------------------------------------------------- platform: hospitals ----
-- Metadata and counts only (no patient/appointment data).
create or replace function identity.platform_list_tenants(p_search text default null, p_status text default null)
returns table (
  id uuid, code text, name text, status text, time_zone text, created_on timestamptz,
  branch_count bigint, user_count bigint, pending_invites bigint, status_reason text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform identity.require_platform_admin();
  return query
    select t.id, t.code, t.name, t.status, t.time_zone, t.created_on,
           (select count(*) from identity.branches b where b.tenant_id = t.id and not b.is_deleted),
           (select count(distinct m.user_id) from identity.memberships m
             where m.tenant_id = t.id and m.status = 'active' and not m.is_deleted),
           (select count(*) from identity.invite_links l
             where l.tenant_id = t.id and l.status = 'pending' and l.expires_on > now() and not l.is_deleted),
           (select c.reason from identity.tenant_status_changes c where c.tenant_id = t.id order by c.created_on desc limit 1)
    from identity.tenants t
    where not t.is_deleted
      and (p_status is null or t.status = p_status)
      and (p_search is null or btrim(p_search) = ''
           or t.name ilike '%' || btrim(p_search) || '%' or t.code ilike '%' || btrim(p_search) || '%')
    order by t.name
    limit 500;
end;
$$;
revoke all on function identity.platform_list_tenants(text, text) from public, anon;
grant execute on function identity.platform_list_tenants(text, text) to authenticated;

create or replace function identity.platform_tenant_history(p_tenant_id uuid)
returns table (from_status text, to_status text, reason text, changed_on timestamptz, changed_by_email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform identity.require_platform_admin();
  return query
    select c.from_status, c.to_status, c.reason, c.created_on, p.email
    from identity.tenant_status_changes c
    left join identity.user_profiles p on p.id = c.created_by
    where c.tenant_id = p_tenant_id and not c.is_deleted
    order by c.created_on desc
    limit 50;
end;
$$;
revoke all on function identity.platform_tenant_history(uuid) from public, anon;
grant execute on function identity.platform_tenant_history(uuid) to authenticated;

create or replace function identity.platform_create_tenant(p_code text, p_name text, p_time_zone text, p_admin_email text)
returns table (tenant_id uuid, invite_link_id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_link record;
begin
  perform identity.require_platform_admin();
  if p_admin_email is null or btrim(p_admin_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'adminEmail: a valid first-admin email is required' using errcode = '22023';
  end if;
  v_tenant := identity.create_tenant(p_code, p_name, p_time_zone, null);
  select * into v_link from identity.issue_invite_link(v_tenant, p_admin_email, 'tenant_admin', null, 'platform');
  return query select v_tenant, v_link.id, v_link.token, v_link.expires_on;
end;
$$;
revoke all on function identity.platform_create_tenant(text, text, text, text) from public, anon;
grant execute on function identity.platform_create_tenant(text, text, text, text) to authenticated;

-- Re-issue the first-admin link (e.g. it expired or was lost); supersedes the pending one.
create or replace function identity.platform_reissue_admin_invite(p_tenant_id uuid, p_admin_email text)
returns table (invite_link_id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_platform_admin();
  if not exists (select 1 from identity.tenants t where t.id = p_tenant_id and not t.is_deleted) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if p_admin_email is null or btrim(p_admin_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'adminEmail: a valid email is required' using errcode = '22023';
  end if;
  return query select l.id, l.token, l.expires_on
    from identity.issue_invite_link(p_tenant_id, p_admin_email, 'tenant_admin', null, 'platform') l;
end;
$$;
revoke all on function identity.platform_reissue_admin_invite(uuid, text) from public, anon;
grant execute on function identity.platform_reissue_admin_invite(uuid, text) to authenticated;

-- Soft suspend / reactivate with a reason. Suspended: every grant helper returns nothing, so staff
-- lose access on their next request (the API resolves memberships per request).
create or replace function identity.platform_set_tenant_status(p_tenant_id uuid, p_status text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old text;
begin
  perform identity.require_platform_admin();
  if p_status not in ('active', 'suspended') then
    raise exception 'status: must be active or suspended' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'reason: give a reason of 3-500 characters' using errcode = '22023';
  end if;
  select t.status into v_old from identity.tenants t where t.id = p_tenant_id and not t.is_deleted for update;
  if v_old is null then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if v_old = p_status then
    raise exception 'The hospital is already %.', p_status using errcode = '55000';
  end if;
  if v_old not in ('active', 'suspended') then
    raise exception 'Archived hospitals cannot be changed here.' using errcode = '55000';
  end if;
  update identity.tenants t set status = p_status where t.id = p_tenant_id;
  insert into identity.tenant_status_changes (tenant_id, from_status, to_status, reason)
  values (p_tenant_id, v_old, p_status, btrim(p_reason));
end;
$$;
revoke all on function identity.platform_set_tenant_status(uuid, text, text) from public, anon;
grant execute on function identity.platform_set_tenant_status(uuid, text, text) to authenticated;

-- ------------------------------------------------- tenant admin: invite links ----
create or replace function identity.create_member_invite_link(p_tenant_id uuid, p_email text, p_role text, p_branch_id uuid default null)
returns table (id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can invite staff' using errcode = '42501';
  end if;
  if p_branch_id is not null and not exists (
       select 1 from identity.branches b where b.tenant_id = p_tenant_id and b.id = p_branch_id and not b.is_deleted) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if p_email is null or btrim(p_email) !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'email: a valid email is required' using errcode = '22023';
  end if;
  return query select l.id, l.token, l.expires_on
    from identity.issue_invite_link(p_tenant_id, p_email, p_role, p_branch_id, 'tenant_admin', interval '7 days') l;
end;
$$;
revoke all on function identity.create_member_invite_link(uuid, text, text, uuid) from public, anon;
grant execute on function identity.create_member_invite_link(uuid, text, text, uuid) to authenticated;

-- Links the admin issued (any email they typed; reveals nothing about accounts).
create or replace function identity.list_member_invite_links(p_tenant_id uuid)
returns table (id uuid, email text, role text, branch_id uuid, status text, expires_on timestamptz, created_on timestamptz, claimed_on timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can list invites' using errcode = '42501';
  end if;
  return query
    select l.id, l.email, l.role, l.branch_id,
           case when l.status = 'pending' and l.expires_on <= now() then 'expired' else l.status end,
           l.expires_on, l.created_on, l.claimed_on
    from identity.invite_links l
    where l.tenant_id = p_tenant_id and not l.is_deleted
    order by l.created_on desc
    limit 200;
end;
$$;
revoke all on function identity.list_member_invite_links(uuid) from public, anon;
grant execute on function identity.list_member_invite_links(uuid) to authenticated;

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
end;
$$;
revoke all on function identity.revoke_invite_link(uuid, uuid) from public, anon;
grant execute on function identity.revoke_invite_link(uuid, uuid) to authenticated;

-- ------------------------------------------------------- invitee: links ----
-- Preview for the invite page (anonymous allowed: the token is the secret). Masked email only.
create or replace function identity.preview_invite_link(p_token text)
returns table (tenant_name text, role text, branch_name text, email_hint text, expires_on timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select t.name, l.role, b.name,
         left(l.email, 1) || repeat('*', greatest(length(split_part(l.email, '@', 1)) - 1, 1)) || '@' || split_part(l.email, '@', 2),
         l.expires_on
  from identity.invite_links l
  join identity.tenants t on t.id = l.tenant_id
  left join identity.branches b on b.id = l.branch_id
  where l.token_hash = identity.invite_token_hash(p_token)
    and l.status = 'pending' and l.expires_on > now() and not l.is_deleted
    and t.status = 'active' and not t.is_deleted
$$;
revoke all on function identity.preview_invite_link(text) from public;
grant execute on function identity.preview_invite_link(text) to anon, authenticated;

-- Claim: the signed-in user's email must equal the invited email. Creates (or activates the
-- matching invited) membership for the invitee themself; claiming IS the consent. An existing
-- suspended membership is never re-activated by a link.
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
    v_membership := v_m.id;  -- already an active member: the link is simply used up
  end if;

  update identity.invite_links l
     set status = 'claimed', claimed_by = v_uid, claimed_on = now(), membership_id = v_membership
   where l.id = v_l.id;
  return query
    select v_l.tenant_id, t.name, m.role, m.branch_id
    from identity.memberships m join identity.tenants t on t.id = m.tenant_id
    where m.id = v_membership;
end;
$$;
revoke all on function identity.claim_invite_link(text) from public, anon;
grant execute on function identity.claim_invite_link(text) to authenticated;

-- --------------------------------------------- operator access (out of band) ----
-- Grants platform-operator access to an EXISTING auth user. Not callable by clients or the API:
-- run by the database owner via scripts/ops/grant-platform-admin.sh (APPROVED=1).
create or replace function identity.grant_platform_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_email text;
begin
  select u.id, u.email into v_user, v_email from auth.users u where lower(u.email) = lower(btrim(p_email)) order by u.id limit 1;
  if v_user is null then
    raise exception 'no auth user with that email; the person must sign up first' using errcode = 'P0002';
  end if;
  insert into identity.user_profiles (id, email) values (v_user, v_email) on conflict (id) do nothing;
  insert into identity.platform_admins (user_id) values (v_user) on conflict (user_id) do nothing;
  return v_user;
end;
$$;
revoke all on function identity.grant_platform_admin(text) from public, anon, authenticated, service_role;
