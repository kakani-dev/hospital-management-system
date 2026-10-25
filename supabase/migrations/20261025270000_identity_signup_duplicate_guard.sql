-- Hospital sign-up: block an email that already belongs to an approved request or a
-- live tenant admin, and flag (do not reject) a request whose normalized hospital name
-- or contact phone matches an existing tenant or another pending request.
--
-- Races: submit takes sorted transaction advisory locks (email, name, phone, source,
-- global queue) before the checks, and the partial unique index
-- tenant_signup_one_pending_per_email is the backstop for two pending rows. Approving
-- a request and activating a tenant_admin membership take the same email lock before
-- they become visible, so a concurrent sign-up cannot pass the check on a stale read.
--
-- The anonymous caller learns only that the email is already registered (P0001
-- email_already_registered). Match ids stay on the request for the platform operator.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ----------------------------------------------------------------- normalize ----
-- Lowercase, strip punctuation and spaces, then drop trailing hospital/clinic suffixes.
-- An empty key (the name was only a suffix) matches nothing, so it cannot flag every row.
create or replace function identity.hospital_name_key(p_name text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
    pg_catalog.regexp_replace(pg_catalog.lower(pg_catalog.btrim(coalesce(p_name, ''))), '[^a-z0-9]', '', 'g'),
    '(hospitals|hospital|clinics|clinic)+$',
    '')
$$;
revoke all on function identity.hospital_name_key(text) from public, anon;
-- Name updates evaluate this from the index expression, so writers need EXECUTE.
-- Anon never writes tenants; the sign-up trigger is security definer and calls it as owner.
grant execute on function identity.hospital_name_key(text) to authenticated, service_role, hms_svc_identity;

-- Digits only. A leading 91 is the country code when ten national digits follow (+91).
-- A single leading 0 is the trunk prefix on the same ten-digit national number.
-- A ten-digit number that merely starts with 91 is left as-is.
create or replace function identity.phone_key(p_phone text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when digits ~ '^91[0-9]{10}$' then pg_catalog.substr(digits, 3)
    when digits ~ '^0[0-9]{10}$' then pg_catalog.substr(digits, 2)
    else digits
  end
  from (
    select pg_catalog.regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as digits
  ) d
$$;
revoke all on function identity.phone_key(text) from public, anon, authenticated;

-- Sorted advisory transaction locks. Callers pass every key they need; the sort is
-- the deadlock order (two sign-ups never lock the same keys in opposite orders).
create or replace function identity.signup_lock_keys(p_keys text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  for v_key in
    select k
      from unnest(coalesce(p_keys, '{}'::text[])) as u(k)
     where k is not null and k <> ''
     order by k
  loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_key, 0));
  end loop;
end;
$$;
revoke all on function identity.signup_lock_keys(text[]) from public, anon, authenticated;

create or replace function identity.signup_lock_key(p_key text)
returns void
language sql
security definer
set search_path = ''
as $$
  select identity.signup_lock_keys(array[p_key])
$$;
revoke all on function identity.signup_lock_key(text) from public, anon, authenticated;

-- True when this email already belongs to an approved hospital or an active
-- tenant_admin of a live (status active, not deleted) tenant. Rejected requests,
-- invited or suspended memberships, and suspended or archived tenants do not count.
-- The message is a fixed token: callers must not attach a hospital name or id.
create or replace function identity.signup_email_registered(p_email text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_email <> ''
     and (
       exists (
         select 1 from identity.tenant_signup_requests r
          where lower(r.contact_email) = p_email and r.status = 'approved' and not r.is_deleted)
       or exists (
         select 1
           from identity.memberships m
           join identity.tenants t on t.id = m.tenant_id
           join auth.users u on u.id = m.user_id
          where m.role = 'tenant_admin' and m.status = 'active' and not m.is_deleted
            and t.status = 'active' and not t.is_deleted
            and lower(pg_catalog.btrim(u.email)) = p_email)
       or exists (
         select 1
           from identity.memberships m
           join identity.tenants t on t.id = m.tenant_id
           join identity.user_profiles up on up.id = m.user_id
          where m.role = 'tenant_admin' and m.status = 'active' and not m.is_deleted
            and t.status = 'active' and not t.is_deleted
            and not up.is_deleted
            and lower(pg_catalog.btrim(up.email)) = p_email)
     )
$$;
revoke all on function identity.signup_email_registered(text) from public, anon, authenticated;

-- ------------------------------------------------------------------- columns ----
alter table identity.tenant_signup_requests
  add column name_key text not null default '',
  add column phone_key text not null default '',
  add column possible_duplicate boolean not null default false,
  add column duplicate_tenant_ids uuid[] not null default '{}',
  add column duplicate_request_ids uuid[] not null default '{}';

alter table identity.tenant_signup_requests
  add constraint tenant_signup_duplicate_flag_check check (
    not possible_duplicate
    or cardinality(duplicate_tenant_ids) > 0
    or cardinality(duplicate_request_ids) > 0);

comment on column identity.tenant_signup_requests.name_key is
  'hospital_name_key(hospital_name). Empty matches nothing.';
comment on column identity.tenant_signup_requests.phone_key is
  'phone_key(phone): digits, with +91 / leading 0 folded to the national number.';
comment on column identity.tenant_signup_requests.possible_duplicate is
  'Set when the request was filed against a matching tenant or pending request. The operator list recomputes matches live; approving a live match requires p_confirm_duplicate.';
comment on column identity.tenant_signup_requests.duplicate_tenant_ids is
  'Tenants matched by normalized name or phone at filing time (and refreshed on approve).';
comment on column identity.tenant_signup_requests.duplicate_request_ids is
  'Other pending requests matched by normalized name or phone.';

-- Live matches for one request. kind is 'tenant' or 'request'. Empty name/phone keys
-- match nothing. Soft-deleted requests are ignored. A tenant matches by its current
-- name, or by the phone stored on a sign-up that created it. Created after the key
-- columns: a language-sql function is parsed against the table as it exists now.
create or replace function identity.signup_duplicate_hits(p_request_id uuid, p_name_key text, p_phone_key text)
returns table (kind text, ref_id uuid, hospital_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select 'tenant'::text, t.id, t.name
    from identity.tenants t
   where coalesce(p_name_key, '') <> ''
     and not t.is_deleted
     and identity.hospital_name_key(t.name) = p_name_key
  union
  select 'tenant'::text, t.id, t.name
    from identity.tenant_signup_requests r
    join identity.tenants t on t.id = r.tenant_id and not t.is_deleted
   where r.tenant_id is not null
     and not r.is_deleted
     and r.id is distinct from p_request_id
     and coalesce(p_phone_key, '') <> ''
     and r.phone_key = p_phone_key
  union
  select 'request'::text, r.id, r.hospital_name
    from identity.tenant_signup_requests r
   where r.status = 'pending'
     and not r.is_deleted
     and r.id is distinct from p_request_id
     and (
       (coalesce(p_name_key, '') <> '' and r.name_key = p_name_key)
       or (coalesce(p_phone_key, '') <> '' and r.phone_key = p_phone_key)
     )
$$;
revoke all on function identity.signup_duplicate_hits(uuid, text, text) from public, anon, authenticated;

create or replace function identity.tenant_signup_set_keys()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.contact_email := lower(pg_catalog.btrim(coalesce(new.contact_email, '')));
  new.hospital_name := pg_catalog.btrim(new.hospital_name);
  new.phone := pg_catalog.btrim(new.phone);
  new.name_key := identity.hospital_name_key(new.hospital_name);
  new.phone_key := identity.phone_key(new.phone);
  return new;
end;
$$;
revoke all on function identity.tenant_signup_set_keys() from public, anon, authenticated;

create trigger tenant_signup_requests_set_keys
  before insert or update of hospital_name, phone, contact_email
  on identity.tenant_signup_requests
  for each row execute function identity.tenant_signup_set_keys();

update identity.tenant_signup_requests
   set name_key = identity.hospital_name_key(hospital_name),
       phone_key = identity.phone_key(phone);

create index tenant_signup_name_key_idx
  on identity.tenant_signup_requests (name_key)
  where not is_deleted and name_key <> '';
create index tenant_signup_phone_key_idx
  on identity.tenant_signup_requests (phone_key)
  where not is_deleted and phone_key <> '';
create index tenants_hospital_name_key_idx
  on identity.tenants (identity.hospital_name_key(name));

-- Activating a tenant admin takes the email lock before the row is visible as active.
create or replace function identity.signup_lock_admin_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth text;
  v_profile text;
begin
  select lower(pg_catalog.btrim(u.email)), lower(pg_catalog.btrim(up.email))
    into v_auth, v_profile
    from auth.users u
    left join identity.user_profiles up on up.id = u.id and not up.is_deleted
   where u.id = new.user_id;
  perform identity.signup_lock_keys(array['signup:e:' || v_auth, 'signup:e:' || v_profile]);
  return new;
end;
$$;
revoke all on function identity.signup_lock_admin_email() from public, anon, authenticated;

create trigger memberships_signup_email_lock
  before insert or update of role, status, is_deleted, user_id
  on identity.memberships
  for each row
  when (new.role = 'tenant_admin' and new.status = 'active' and not new.is_deleted)
  execute function identity.signup_lock_admin_email();

create or replace function identity.signup_lock_approved_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    perform identity.signup_lock_key('signup:e:' || lower(pg_catalog.btrim(new.contact_email)));
  end if;
  return new;
end;
$$;
revoke all on function identity.signup_lock_approved_email() from public, anon, authenticated;

create trigger tenant_signup_requests_email_lock
  before update of status on identity.tenant_signup_requests
  for each row execute function identity.signup_lock_approved_email();

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
  v_email text := lower(pg_catalog.btrim(coalesce(p_contact_email, '')));
  v_name text := pg_catalog.btrim(p_hospital_name);
  v_contact text := pg_catalog.btrim(p_contact_name);
  v_name_key text := identity.hospital_name_key(p_hospital_name);
  v_phone_key text := identity.phone_key(p_phone);
  v_tenant_ids uuid[];
  v_request_ids uuid[];
  v_duplicate boolean;
begin
  if not identity.is_valid_time_zone(p_time_zone) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', coalesce(p_time_zone, 'null') using errcode = '22023';
  end if;

  -- Cheap validation failed above without locks. Everything that reads or writes
  -- the queue holds the locks until this transaction ends.
  perform identity.signup_lock_keys(array[
    'signup:e:' || v_email,
    case when v_name_key <> '' then 'signup:n:' || v_name_key end,
    case when v_phone_key <> '' then 'signup:p:' || v_phone_key end,
    case when p_source_hash is not null then 'signup:s:' || p_source_hash end,
    'signup:queue']);

  if p_source_hash is not null and (
       select count(*) from identity.tenant_signup_requests r
        where r.source_hash = p_source_hash and r.created_on > pg_catalog.now() - interval '24 hours') >= 3 then
    raise exception 'rate_limited: too many hospital registrations from this source' using errcode = '54000';
  end if;
  if (select count(*) from identity.tenant_signup_requests r where r.status = 'pending' and not r.is_deleted) >= 200 then
    raise exception 'rate_limited: the registration queue is full' using errcode = '54000';
  end if;
  -- Same pending email: one row, one acknowledgement. A concurrent insert hits the
  -- unique index below and takes this same path (202, no second email).
  if exists (select 1 from identity.tenant_signup_requests r
              where lower(r.contact_email) = v_email and r.status = 'pending' and not r.is_deleted) then
    return null;
  end if;
  if identity.signup_email_registered(v_email) then
    raise exception 'email_already_registered' using errcode = 'P0001';
  end if;

  select coalesce(array_agg(h.ref_id order by h.ref_id) filter (where h.kind = 'tenant'), '{}'),
         coalesce(array_agg(h.ref_id order by h.ref_id) filter (where h.kind = 'request'), '{}')
    into v_tenant_ids, v_request_ids
    from identity.signup_duplicate_hits(null, v_name_key, v_phone_key) h;
  v_duplicate := cardinality(v_tenant_ids) > 0 or cardinality(v_request_ids) > 0;

  insert into identity.tenant_signup_requests (
    hospital_name, time_zone, contact_name, contact_email, phone, city, source_hash,
    possible_duplicate, duplicate_tenant_ids, duplicate_request_ids)
  values (v_name, identity.canonical_time_zone(p_time_zone), v_contact, v_email,
          pg_catalog.btrim(p_phone), pg_catalog.btrim(p_city), p_source_hash,
          v_duplicate, v_tenant_ids, v_request_ids)
  on conflict do nothing
  returning id into v_id;
  if v_id is null then
    return null;
  end if;

  -- The other pending request was filed first and did not yet point at this one.
  update identity.tenant_signup_requests r
     set possible_duplicate = true,
         duplicate_request_ids = (
           select coalesce(array_agg(distinct x order by x), '{}')
             from unnest(r.duplicate_request_ids || array[v_id]) as u(x)
            where x is not null)
   where r.id = any (v_request_ids)
     and r.status = 'pending'
     and not r.is_deleted;

  perform identity.enqueue_email(null, v_id, 'signup_received', v_email, pg_catalog.jsonb_build_object(
    'hospitalName', v_name,
    'contactName', v_contact));
  return v_id;
end;
$$;
revoke all on function identity.submit_tenant_signup(text, text, text, text, text, text, text) from public;
grant execute on function identity.submit_tenant_signup(text, text, text, text, text, text, text) to anon, authenticated, service_role;

-- ------------------------------------------------ platform: sign-up queue ----
-- Return shape gains possible_duplicate and matched_hospitals (live, not the stored snapshot).
drop function identity.platform_list_signups(text);

create function identity.platform_list_signups(p_status text default null)
returns table (
  id uuid, hospital_name text, time_zone text, contact_name text, contact_email text, phone text, city text,
  status text, decision_reason text, decided_on timestamptz, tenant_id uuid, tenant_code text, created_on timestamptz,
  possible_duplicate boolean, matched_hospitals text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform identity.require_platform_admin();
  return query
    select r.id, r.hospital_name, r.time_zone, r.contact_name, r.contact_email, r.phone, r.city,
           r.status, r.decision_reason, r.decided_on, r.tenant_id, t.code, r.created_on,
           coalesce(h.is_dup, false),
           coalesce(h.names, '{}'::text[])
      from identity.tenant_signup_requests r
      left join identity.tenants t on t.id = r.tenant_id
      left join lateral (
        select (count(*) > 0) as is_dup,
               coalesce(array_agg(distinct hit.hospital_name order by hit.hospital_name), '{}'::text[]) as names
          from identity.signup_duplicate_hits(r.id, r.name_key, r.phone_key) hit
      ) h on true
     where not r.is_deleted
       and (p_status is null or r.status = p_status)
     order by (r.status = 'pending') desc, r.created_on desc
     limit 500;
end;
$$;
revoke all on function identity.platform_list_signups(text) from public, anon;
grant execute on function identity.platform_list_signups(text) to authenticated, service_role, hms_svc_identity;

drop function identity.platform_approve_signup(uuid, text);

create function identity.platform_approve_signup(
  p_request_id uuid, p_tenant_code text, p_confirm_duplicate boolean default false)
returns table (tenant_id uuid, invite_link_id uuid, token text, expires_on timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r identity.tenant_signup_requests%rowtype;
  v_email text;
  v_tenant uuid;
  v_link record;
  v_tenant_ids uuid[];
  v_request_ids uuid[];
  v_duplicate boolean;
begin
  perform identity.require_platform_admin();

  -- Lock the email before the row so a concurrent submit blocks on the same key
  -- instead of deadlocking on (row lock, then email lock).
  select lower(pg_catalog.btrim(r.contact_email)) into v_email
    from identity.tenant_signup_requests r
   where r.id = p_request_id and not r.is_deleted;
  if v_email is not null then
    perform identity.signup_lock_key('signup:e:' || v_email);
  end if;

  select * into v_r from identity.tenant_signup_requests r where r.id = p_request_id and not r.is_deleted for update;
  if v_r.id is null then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'This request was already %.', v_r.status using errcode = '55000';
  end if;

  -- Recompute. A tenant created after the request was filed still requires confirm,
  -- and a match that has since gone away does not.
  select coalesce(array_agg(h.ref_id order by h.ref_id) filter (where h.kind = 'tenant'), '{}'),
         coalesce(array_agg(h.ref_id order by h.ref_id) filter (where h.kind = 'request'), '{}')
    into v_tenant_ids, v_request_ids
    from identity.signup_duplicate_hits(v_r.id, v_r.name_key, v_r.phone_key) h;
  v_duplicate := cardinality(v_tenant_ids) > 0 or cardinality(v_request_ids) > 0;
  if v_duplicate and not coalesce(p_confirm_duplicate, false) then
    raise exception 'possible_duplicate' using errcode = 'P0001';
  end if;

  update identity.tenant_signup_requests r
     set possible_duplicate = v_duplicate,
         duplicate_tenant_ids = v_tenant_ids,
         duplicate_request_ids = v_request_ids
   where r.id = v_r.id;

  v_tenant := identity.create_tenant(p_tenant_code, v_r.hospital_name, v_r.time_zone, null);
  -- The approval email carries the first-admin link. Do not also send invite_link.
  select * into v_link from identity.issue_invite_link(
    v_tenant, v_r.contact_email, 'tenant_admin', null, 'signup_approval', interval '14 days', false);

  update identity.tenant_signup_requests r
     set status = 'approved', decided_by = auth.uid(), decided_on = pg_catalog.now(), tenant_id = v_tenant, invite_link_id = v_link.id
   where r.id = v_r.id;

  perform identity.enqueue_email(v_tenant, v_r.id, 'signup_approved', v_r.contact_email, pg_catalog.jsonb_build_object(
    'hospitalName', v_r.hospital_name,
    'contactName', v_r.contact_name,
    'role', 'tenant_admin',
    'token', v_link.token,
    'expiresOn', v_link.expires_on), v_link.id);

  return query select v_tenant, v_link.id, v_link.token, v_link.expires_on;
end;
$$;
revoke all on function identity.platform_approve_signup(uuid, text, boolean) from public, anon;
grant execute on function identity.platform_approve_signup(uuid, text, boolean) to authenticated, service_role, hms_svc_identity;
