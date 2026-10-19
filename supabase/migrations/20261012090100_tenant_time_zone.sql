-- =============================================================================
-- Tenant time zone (AUDIT-TZ-PLAN.md §B, approved 2026-10-09).
--
--  1. identity.tenants.time_zone: REQUIRED IANA zone. identity.is_valid_time_zone() (review S6) is a
--     cheap check: Area/City shape (or UTC), a denylist (localtime, posixrules, Factory, posix/*,
--     right/*, and every Etc/* except Etc/UTC: Etc/GMT+5 means UTC-5, re-review N3) and a probe of
--     the zone; legacy aliases such as Asia/Calcutta are accepted and stored canonically
--     (Asia/Kolkata) by the guard trigger, including existing branch overrides (re-review N4).
--     Existing tenants are back-filled with 'Asia/Kolkata' (the only zone in use so far).
--  2. Branch override (decision E1), EXPAND-then-contract (code review MAJ-1): the new nullable
--     identity.branches.timezone_override holds the override (NULL = inherit the tenant zone).
--     identity.branches.timezone keeps its old shape (NOT NULL) as a DERIVED mirror of the effective
--     zone, so readers built before this migration (main's API, services deploying independently)
--     keep working; legacy writes to it are read as an override (same validation and locks).
--     A tenant zone change cascades to the mirror of inheriting branches. Existing branches: a zone
--     different from the tenant's becomes timezone_override. Contract step: docs/runbooks/audit-columns-contract.md.
--  3. identity.branch_time_zone_v1(branch) = coalesce(branch override, tenant zone) and
--     identity.branch_local_date_v1(branch, at) (published to every service; P0002 for an unknown or
--     foreign branch) are the ONLY places that decide a branch's calendar
--     day. Queue day / token reset (issue_queue_token), the "today" check in check_in, slot
--     generation (available_slots, DST-safe: code review MIN-1) and the schedules.valid_from default all use them.
--  4. schedules.valid_from no longer defaults to current_date (that is the UTC date on Supabase,
--     i.e. "yesterday" between 00:00 and 05:30 IST); a missing value is filled branch-locally.
--  5. Zone changes (tenant zone, or a branch override) go through identity.change_time_zone_v1:
--     refused with 55000 time_zone_locked while the affected branches have queue entries for today
--     (decision E3), and they need confirmation when future bookings would shift (re-review R5):
--     without it nothing changes and the count is returned. Clients have no direct UPDATE grant on
--     tenants.time_zone / branches.timezone_override; any non-owner writer that bypasses the function
--     (service_role, a legacy writer of branches.timezone) gets 55000 time_zone_has_future_bookings.
--  6. identity.platform_admins + identity.create_tenant(): the create-tenant SQL (code, name, time
--     zone, default branch, optional first-admin invitation) for platform admins or the identity
--     service (service_role). The HTTP endpoint lives in the identity service (code review MIN-5).
-- =============================================================================

-- Hosted rollout (code review MIN-4): never queue behind live traffic for long; see
-- docs/runbooks/deploy-sprint-2-hosted.md (order, quiet window, verification).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- Legacy IANA aliases still produced by some browsers/OSes -> canonical names. Stored values are
-- always canonical (the guard trigger rewrites them), so every service sees one spelling.
create or replace function identity.canonical_time_zone(p_zone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_zone
    when 'Asia/Calcutta'        then 'Asia/Kolkata'
    when 'Asia/Saigon'          then 'Asia/Ho_Chi_Minh'
    when 'Asia/Katmandu'        then 'Asia/Kathmandu'
    when 'Asia/Rangoon'         then 'Asia/Yangon'
    when 'Asia/Dacca'           then 'Asia/Dhaka'
    when 'Asia/Thimbu'          then 'Asia/Thimphu'
    when 'America/Buenos_Aires' then 'America/Argentina/Buenos_Aires'
    when 'Etc/UTC'              then 'UTC'
    else p_zone
  end
$$;
revoke all on function identity.canonical_time_zone(text) from public;
grant execute on function identity.canonical_time_zone(text) to authenticated, service_role;

create or replace function identity.is_valid_time_zone(p_zone text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_zone is null or length(p_zone) not between 3 and 64 then
    return false;
  end if;
  -- shape: UTC, or Area/City[/Sub] (rejects abbreviations such as IST/EST and lower-case pseudo
  -- zones). No '+' and no digits after a letter-led segment: the probe below would accept a POSIX
  -- suffix ('Asia/Kolkata+5' = UTC-5, code review MIN-2). Etc/* is handled by the denylist.
  if p_zone !~ '^(UTC|[A-Z][A-Za-z_-]+(/[A-Z][A-Za-z_-]*){1,2})$' then
    return false;
  end if;
  -- pseudo zones that resolve but must never be stored (localtime = the SERVER zone, UTC on Supabase);
  -- Etc/GMT+N has the POSIX inverted sign (Etc/GMT+5 = UTC-5), so only Etc/UTC is allowed from Etc/*
  if p_zone in ('localtime', 'posixrules', 'Factory') or p_zone like 'posix/%' or p_zone like 'right/%'
     or (p_zone like 'Etc/%' and p_zone <> 'Etc/UTC') then
    return false;
  end if;
  -- cheap probe instead of scanning the tz name catalog view (~14 ms per call); legacy aliases are
  -- probed by their canonical name (servers without the tzdata "backward" links know only that)
  begin
    perform pg_catalog.now() at time zone identity.canonical_time_zone(p_zone);
  exception when others then
    return false;
  end;
  return true;
end;
$$;
revoke all on function identity.is_valid_time_zone(text) from public;
grant execute on function identity.is_valid_time_zone(text) to authenticated, service_role;

-- ----------------------------------------------------------------- columns ----
alter table identity.tenants add column time_zone text;
alter table identity.tenants disable trigger user;
update identity.tenants set time_zone = 'Asia/Kolkata' where time_zone is null;
alter table identity.tenants enable trigger user;
alter table identity.tenants alter column time_zone set not null;
comment on column identity.tenants.time_zone is
  'REQUIRED IANA zone of the hospital. Every day-based rule (queue day, today''s board, slots, schedule defaults) uses it unless a branch overrides it.';

-- EXPAND (code review MAJ-1): branches.timezone keeps its old meaning and shape (NOT NULL, the
-- branch's zone) so readers built before this migration keep working; it becomes a DERIVED mirror
-- of the effective zone. The override lives in the new nullable column timezone_override.
alter table identity.branches add column timezone_override text;
alter table identity.branches alter column timezone drop default;  -- the guard trigger fills it
alter table identity.branches disable trigger user;
-- stored values are always canonical (re-review N4): existing aliases (Asia/Calcutta) too
update identity.branches set timezone = identity.canonical_time_zone(timezone)
 where timezone is distinct from identity.canonical_time_zone(timezone);
-- a branch whose zone differs from its tenant's keeps it as an explicit override
update identity.branches b set timezone_override = b.timezone
  from identity.tenants t
 where t.id = b.tenant_id and b.timezone is distinct from identity.canonical_time_zone(t.time_zone);
alter table identity.branches enable trigger user;
-- existing zones must be valid too (the trigger below only checks future writes)
do $$
declare
  v_bad text;
begin
  select string_agg(distinct b.timezone, ', ') into v_bad
  from identity.branches b where not identity.is_valid_time_zone(b.timezone);
  if v_bad is not null then
    raise exception 'invalid branch time zone(s): % (fix them before applying this migration)', v_bad
      using errcode = '22023';
  end if;
end;
$$;
comment on column identity.branches.timezone_override is
  'Optional IANA override of identity.tenants.time_zone for this branch. NULL = inherit the tenant zone. Changed through identity.change_time_zone_v1.';
comment on column identity.branches.timezone is
  'DEPRECATED (expand/contract, code review MAJ-1): DERIVED effective zone = coalesce(timezone_override, tenant time_zone), kept by identity.guard_time_zone / cascade_tenant_time_zone. Legacy writers may still write it (read as an override, same locks); new code uses timezone_override. Dropped in the contract migration.';

-- New clients may set an override when creating a branch; changes go through change_time_zone_v1.
-- UPDATE (timezone) stays granted (20261012090000) for readers/writers built before this migration.
grant insert (timezone_override) on identity.branches to authenticated;

-- --------------------------------------------------------- zone resolution ----
-- cross-schema: approved (published v1 surface, DB review B2 / S7)
create or replace function identity.branch_time_zone_v1(p_branch_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_zone text;
begin
  select b.tenant_id, coalesce(b.timezone_override, t.time_zone) into v_tenant, v_zone
  from identity.branches b
  join identity.tenants t on t.id = b.tenant_id
  where b.id = p_branch_id;
  -- unknown, or (for a client session: JWT sub OR session role authenticated/anon, re-review R4)
  -- another tenant's branch: 404-not-403 (review N1)
  if v_zone is null
     or ((auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
         and v_tenant not in (select identity.current_tenant_ids())) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  return v_zone;
end;
$$;
comment on function identity.branch_time_zone_v1(uuid) is
  'v1 (published by identity): effective IANA zone of a branch = its override, else the tenant zone. P0002 for unknown/foreign branches.';

-- cross-schema: approved (published v1 surface, DB review B2 / S7)
create or replace function identity.branch_local_date_v1(p_branch_id uuid, p_at timestamptz default now())
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return (p_at at time zone identity.branch_time_zone_v1(p_branch_id))::date;
end;
$$;
comment on function identity.branch_local_date_v1(uuid, timestamptz) is
  'v1 (published by identity): calendar date of an instant at the branch (queue day, today, schedule defaults).';

revoke all on function identity.branch_time_zone_v1(uuid) from public, anon;
revoke all on function identity.branch_local_date_v1(uuid, timestamptz) from public, anon;
grant execute on function identity.branch_time_zone_v1(uuid) to authenticated, service_role;
grant execute on function identity.branch_local_date_v1(uuid, timestamptz) to authenticated, service_role;

-- ------------------------------------------- zone change: locks + confirmation ----
-- cross-schema: approved (published v1, DB review B2 / re-review R5)
create or replace function appointment.future_bookings_count_v1(p_tenant_id uuid, p_branch_ids uuid[])
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return (select count(*)::integer from appointment.appointments a
          where a.tenant_id = p_tenant_id and a.branch_id = any (p_branch_ids)
            and a.status = 'booked' and a.starts_at > pg_catalog.now());
end;
$$;
comment on function appointment.future_bookings_count_v1(uuid, uuid[]) is
  'v1 (published by scheduling): number of booked appointments starting after now() in the branches (zone-change confirmation).';
revoke all on function appointment.future_bookings_count_v1(uuid, uuid[]) from public, anon, authenticated;
grant execute on function appointment.future_bookings_count_v1(uuid, uuid[]) to service_role;

-- Raises when a zone change of these branches is not allowed (re-review R5):
--   55000 time_zone_locked                 today's queue (old or new local day) has entries (decision E3)
--   55000 time_zone_has_future_bookings    future bookings would shift, and the change is not confirmed
-- Clients: member (else P0002) with tenant_admin (else 42501). p_confirmed is decided by the caller:
-- identity.guard_time_zone passes "the writer is the table owner" (change_time_zone_v1 after its
-- confirmation step, migrations); a client calling this directly only gets the checks.
create or replace function identity.assert_zone_change_allowed_v1(
  p_tenant_id uuid, p_branch_ids uuid[], p_old_zone text, p_new_zone text, p_confirmed boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon') then
    if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
      raise exception 'tenant not found' using errcode = 'P0002';
    end if;
    if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
      raise exception 'only tenant admins can change the time zone' using errcode = '42501';
    end if;
  end if;
  if p_old_zone is not distinct from p_new_zone or coalesce(cardinality(p_branch_ids), 0) = 0 then
    return;
  end if;
  if appointment.queue_has_entries_v1(
       p_tenant_id, p_branch_ids,
       array[(pg_catalog.now() at time zone p_old_zone)::date, (pg_catalog.now() at time zone p_new_zone)::date]) then
    raise exception 'time_zone_locked: today''s queue already has entries; change the time zone after the day ends'
      using errcode = '55000';
  end if;
  if not coalesce(p_confirmed, false) then
    v_count := appointment.future_bookings_count_v1(p_tenant_id, p_branch_ids);
    if v_count > 0 then
      raise exception 'time_zone_has_future_bookings: % future booking(s) would shift; use identity.change_time_zone_v1 with confirmation', v_count
        using errcode = '55000';
    end if;
  end if;
end;
$$;
revoke all on function identity.assert_zone_change_allowed_v1(uuid, uuid[], text, text, boolean) from public, anon;
grant execute on function identity.assert_zone_change_allowed_v1(uuid, uuid[], text, text, boolean) to authenticated, service_role;

-- Validation, canonicalisation, the branches.timezone mirror and the change locks.
-- SECURITY INVOKER on purpose: current_user is the real writer, so the owner (the definer
-- change_time_zone_v1 after confirmation, cascade, migrations) is told apart from service_role,
-- other service roles and legacy client writers, who can never skip the future-bookings lock.
create or replace function identity.guard_time_zone()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant_tz text;
  v_zone      text;
  v_owner     name;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner from pg_catalog.pg_class c where c.oid = tg_relid;

  if tg_table_name = 'tenants' then
    new.time_zone := identity.canonical_time_zone(new.time_zone);
    -- NULL is left to the NOT NULL constraint (23502)
    if new.time_zone is not null and not identity.is_valid_time_zone(new.time_zone) then
      raise exception 'invalid_time_zone: % is not a known IANA time zone', new.time_zone
        using errcode = '22023';
    end if;
    if tg_op = 'UPDATE' and new.time_zone is distinct from old.time_zone then
      -- the live branches that inherit the tenant zone move with it
      perform identity.assert_zone_change_allowed_v1(
        new.id,
        array(select b.id from identity.branches b
              where b.tenant_id = new.id and b.timezone_override is null and not b.is_deleted),
        old.time_zone, new.time_zone, current_user = v_owner);
    end if;
    return new;
  end if;

  -- branches
  select t.time_zone into v_tenant_tz from identity.tenants t where t.id = new.tenant_id;
  if v_tenant_tz is null then
    -- tenant unknown or invisible to this writer: leave the verdict to RLS (42501) / the FK (23503),
    -- which run after BEFORE triggers; the placeholder mirror can never be stored
    new.timezone := coalesce(new.timezone_override, new.timezone, 'UTC');
    return new;
  end if;
  if tg_op = 'UPDATE' and new.timezone_override is distinct from old.timezone_override then
    new.timezone_override := identity.canonical_time_zone(new.timezone_override);          -- new writers
  elsif (tg_op = 'INSERT' and new.timezone_override is null and new.timezone is not null)
        or (tg_op = 'UPDATE' and new.timezone is distinct from old.timezone) then
    -- legacy writers (or the tenant cascade) write the zone itself: equal to the tenant zone = inherit
    v_zone := identity.canonical_time_zone(new.timezone);
    if v_zone is not null and not identity.is_valid_time_zone(v_zone) then
      raise exception 'invalid_time_zone: % is not a known IANA time zone', v_zone using errcode = '22023';
    end if;
    new.timezone_override := case when v_zone = v_tenant_tz then null else v_zone end;
  else
    new.timezone_override := identity.canonical_time_zone(new.timezone_override);
  end if;
  if new.timezone_override is not null and not identity.is_valid_time_zone(new.timezone_override) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', new.timezone_override using errcode = '22023';
  end if;
  new.timezone := coalesce(new.timezone_override, v_tenant_tz);  -- the mirror is always the effective zone

  if tg_op = 'UPDATE' and new.timezone_override is distinct from old.timezone_override
     and new.timezone is distinct from old.timezone then
    perform identity.assert_zone_change_allowed_v1(
      new.tenant_id, array[new.id], old.timezone, new.timezone, current_user = v_owner);
  end if;
  return new;
end;
$$;
revoke all on function identity.guard_time_zone() from public;

create trigger tenants_time_zone before insert or update on identity.tenants
  for each row execute function identity.guard_time_zone();
create trigger branches_time_zone before insert or update on identity.branches
  for each row execute function identity.guard_time_zone();

-- keeps the branches.timezone mirror of inheriting branches equal to a changed tenant zone
create or replace function identity.cascade_tenant_time_zone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update identity.branches b set timezone = new.time_zone
   where b.tenant_id = new.id and b.timezone_override is null and b.timezone is distinct from new.time_zone;
  return null;
end;
$$;
revoke all on function identity.cascade_tenant_time_zone() from public;
create trigger tenants_time_zone_cascade after update of time_zone on identity.tenants
  for each row when (new.time_zone is distinct from old.time_zone)
  execute function identity.cascade_tenant_time_zone();

-- The only client path for a zone change (tenant zone, or a branch override; p_branch_id NULL = the
-- tenant). p_time_zone NULL on a branch = inherit the tenant zone. With future bookings in the
-- affected branches and p_confirm = false nothing changes and (false, N, current) is returned, so
-- the caller can show N and ask for confirmation (re-review R5).
create or replace function identity.change_time_zone_v1(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_time_zone text,
  p_confirm boolean default false)
returns table (changed boolean, future_bookings integer, time_zone text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zone      text := identity.canonical_time_zone(nullif(btrim(p_time_zone), ''));
  v_tenant_tz text;
  v_override  text;
  v_old_eff   text;
  v_new_eff   text;
  v_branches  uuid[];
  v_count     integer := 0;
begin
  -- client sessions: foreign or unknown tenant -> P0002, member without tenant_admin -> 42501
  if auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon') then
    if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
      raise exception 'tenant not found' using errcode = 'P0002';
    end if;
    if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
      raise exception 'only tenant admins can change the time zone' using errcode = '42501';
    end if;
  end if;

  select t.time_zone into v_tenant_tz from identity.tenants t
  where t.id = p_tenant_id and not t.is_deleted
  for update;
  if not found then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;

  if v_zone is not null and not identity.is_valid_time_zone(v_zone) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', v_zone using errcode = '22023';
  end if;

  if p_branch_id is null then
    if v_zone is null then
      raise exception 'invalid_time_zone: the hospital time zone is required' using errcode = '22023';
    end if;
    v_old_eff := v_tenant_tz;
    v_new_eff := v_zone;
    v_branches := array(select b.id from identity.branches b
                        where b.tenant_id = p_tenant_id and b.timezone_override is null and not b.is_deleted);
  else
    select b.timezone_override into v_override from identity.branches b
    where b.tenant_id = p_tenant_id and b.id = p_branch_id and not b.is_deleted
    for update;
    if not found then
      raise exception 'branch not found' using errcode = 'P0002';
    end if;
    v_old_eff := coalesce(v_override, v_tenant_tz);
    v_new_eff := coalesce(v_zone, v_tenant_tz);
    v_branches := array[p_branch_id];
  end if;

  if v_old_eff is distinct from v_new_eff then
    v_count := appointment.future_bookings_count_v1(p_tenant_id, v_branches);
    if v_count > 0 and not coalesce(p_confirm, false) then
      return query select false, v_count, case when p_branch_id is null then v_tenant_tz else v_override end;
      return;
    end if;
  end if;

  -- the guard trigger still validates and applies today's-queue lock (55000 time_zone_locked)
  if p_branch_id is null then
    update identity.tenants t set time_zone = v_zone where t.id = p_tenant_id;
  else
    update identity.branches b set timezone_override = v_zone where b.id = p_branch_id;
  end if;
  return query select true, v_count, v_zone;
end;
$$;
comment on function identity.change_time_zone_v1(uuid, uuid, text, boolean) is
  'Changes the tenant zone (p_branch_id NULL) or a branch override (p_time_zone NULL = inherit). With future bookings and p_confirm = false nothing changes and (false, count, current) is returned. tenant_admin only for clients.';
revoke all on function identity.change_time_zone_v1(uuid, uuid, text, boolean) from public, anon;
grant execute on function identity.change_time_zone_v1(uuid, uuid, text, boolean) to authenticated, service_role;

-- ------------------------------------------------- schedules.valid_from default ----
alter table appointment.schedules alter column valid_from drop default;

create or replace function appointment.check_schedule_refs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform appointment.assert_tenant_refs(new.tenant_id, new.branch_id);
  if not exists (select 1 from appointment.practitioners pr
                 where pr.tenant_id = new.tenant_id and pr.id = new.practitioner_id and not pr.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if new.valid_from is null then
    new.valid_from := identity.branch_local_date_v1(new.branch_id);  -- branch-local today, never the UTC date
  end if;
  return new;
end;
$$;

-- ---------------------------------------------- day-based functions use the zone ----
create or replace function appointment.issue_queue_token(p_tenant_id uuid, p_branch_id uuid, p_patient_id uuid, p_appointment_id uuid, p_practitioner_id uuid)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date  date;
  v_token integer;
  v_id    uuid;
begin
  if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  -- queue day (and therefore the token reset) = the branch-local calendar day
  v_date := identity.branch_local_date_v1(p_branch_id);

  if exists (select 1 from appointment.queue_entries q
             where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id and q.queue_date = v_date
               and q.patient_id = p_patient_id and q.status in ('waiting', 'in_consultation')) then
    raise exception 'patient already has an active queue entry at this branch today' using errcode = '23505';
  end if;

  insert into appointment.queue_counters as c (tenant_id, branch_id, queue_date, last_token)
  values (p_tenant_id, p_branch_id, v_date, 1)
  on conflict on constraint queue_counters_pkey do update set last_token = c.last_token + 1
  returning c.last_token into v_token;

  insert into appointment.queue_entries (tenant_id, branch_id, queue_date, token_no, patient_id, appointment_id, practitioner_id)
  values (p_tenant_id, p_branch_id, v_date, v_token, p_patient_id, p_appointment_id, p_practitioner_id)
  returning id into v_id;

  queue_entry_id := v_id;
  token_no := v_token;
  queue_date := v_date;
  return next;
end;
$$;

create or replace function appointment.check_in(p_tenant_id uuid, p_branch_id uuid, p_patient_id uuid, p_appointment_id uuid default null, p_practitioner_id uuid default null)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt record;
  v_practitioner uuid := p_practitioner_id;
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin', 'receptionist', 'nurse'])
     or not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'not permitted to check in at this branch' using errcode = '42501';
  end if;

  if not patient.patient_exists_v1(p_tenant_id, p_patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if p_appointment_id is not null then
    select a.id, a.status, a.starts_at, a.practitioner_id into v_appt
    from appointment.appointments a
    where a.tenant_id = p_tenant_id and a.id = p_appointment_id
      and a.branch_id = p_branch_id and a.patient_id = p_patient_id
    for update;
    if v_appt.id is null then
      raise exception 'appointment not found' using errcode = 'P0002';
    end if;
    if exists (select 1 from appointment.queue_entries q where q.appointment_id = v_appt.id) then
      raise exception 'appointment already checked in' using errcode = '23505';
    end if;
    if v_appt.status <> 'booked' then
      raise exception 'invalid_transition:%->checked_in', v_appt.status using errcode = '23514';
    end if;
    if identity.branch_local_date_v1(p_branch_id, v_appt.starts_at) <> identity.branch_local_date_v1(p_branch_id) then
      raise exception 'appointment is not for today at this branch' using errcode = '55000';
    end if;
    v_practitioner := coalesce(p_practitioner_id, v_appt.practitioner_id);
  end if;

  if v_practitioner is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = p_tenant_id and pr.id = v_practitioner and pr.is_active and not pr.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;

  if p_appointment_id is not null then
    perform set_config('appointment.check_in', p_appointment_id::text, true);
    update appointment.appointments set status = 'checked_in' where id = p_appointment_id;
    perform set_config('appointment.check_in', '', true);
  end if;

  return query select * from appointment.issue_queue_token(p_tenant_id, p_branch_id, p_patient_id, p_appointment_id, v_practitioner);
end;
$$;

create or replace function appointment.available_slots(p_tenant_id uuid, p_branch_id uuid, p_from date, p_to date, p_practitioner_id uuid default null)
returns table (practitioner_id uuid, branch_id uuid, slot_start timestamptz, slot_end timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 31 then
    raise exception 'invalid date range (max 31 days)' using errcode = '22023';
  end if;
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if p_practitioner_id is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = p_tenant_id and pr.id = p_practitioner_id and not pr.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'not permitted for this branch' using errcode = '42501';
  end if;
  -- slot wall-clock times are branch-local: tenant zone unless the branch overrides it
  v_tz := identity.branch_time_zone_v1(p_branch_id);

  return query
  with days as (
    select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ), sch as (
    select s.practitioner_id, s.start_time, s.end_time, s.slot_minutes, days.day
    from appointment.schedules s
    join appointment.practitioners pr on pr.tenant_id = s.tenant_id and pr.id = s.practitioner_id
                                     and pr.is_active and not pr.is_deleted
    join days on extract(isodow from days.day) = s.weekday
             and days.day >= s.valid_from and (s.valid_to is null or days.day <= s.valid_to)
    where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.is_active and not s.is_deleted
      and (p_practitioner_id is null or s.practitioner_id = p_practitioner_id)
  ), local_slots as (
    select sch.practitioner_id, sch.slot_minutes,
           (sch.day + sch.start_time) + make_interval(mins => k * sch.slot_minutes) as l_start
    from sch
    cross join lateral generate_series(
      0, (floor(extract(epoch from (sch.end_time - sch.start_time)) / 60 / sch.slot_minutes))::int - 1) k
  ), slots as (
    -- DST (code review MIN-1): each wall-clock slot is offered at most once and lasts slot_minutes
    -- of real time. A local start that does not exist (spring-forward gap) does not round-trip and is
    -- skipped; an ambiguous one (fall-back hour) resolves to one instant (PostgreSQL: standard time).
    select ls.practitioner_id,
           ls.l_start at time zone v_tz as s_start,
           (ls.l_start at time zone v_tz) + make_interval(mins => ls.slot_minutes) as s_end,
           ls.l_start
    from local_slots ls
  )
  select sl.practitioner_id, p_branch_id, sl.s_start, sl.s_end
  from slots sl
  where sl.s_start > now()
    and (sl.s_start at time zone v_tz) = sl.l_start
    and not exists (
      select 1 from appointment.appointments a
      where a.tenant_id = p_tenant_id and a.practitioner_id = sl.practitioner_id
        and a.status in ('booked', 'checked_in', 'in_consultation', 'completed')
        and a.during && tstzrange(sl.s_start, sl.s_end, '[)'))
  order by sl.s_start, sl.practitioner_id;
end;
$$;

-- ------------------------------------------------------- platform admins ----
create table identity.platform_admins (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false
);
comment on table identity.platform_admins is
  'MediCore operators who may create tenants (identity.create_tenant). Managed by service_role only; no client access.';
alter table identity.platform_admins enable row level security;
grant all on identity.platform_admins to service_role;
create trigger platform_admins_audit_columns before insert or update on identity.platform_admins
  for each row execute function audit.stamp_audit_columns();
create trigger platform_admins_audit_log after insert or update or delete on identity.platform_admins
  for each row execute function audit.log_row_change();

create or replace function identity.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from identity.platform_admins pa where pa.user_id = auth.uid() and not pa.is_deleted)
$$;
revoke all on function identity.is_platform_admin() from public, anon;
grant execute on function identity.is_platform_admin() to authenticated, service_role;

-- ---------------------------------------------------------- create tenant ----
create or replace function identity.create_tenant(
  p_code text,
  p_name text,
  p_time_zone text,
  p_admin_email text default null,
  p_branch_code text default 'main',
  p_branch_name text default 'Main')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_branch uuid;
  v_user uuid;
  v_email text;
begin
  -- client sessions must be platform admins; trusted callers (the identity service as service_role)
  -- may create tenants on behalf of an operator
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and not identity.is_platform_admin() then
    raise exception 'only platform admins can create tenants' using errcode = '42501';
  end if;
  if not identity.is_valid_time_zone(p_time_zone) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', coalesce(p_time_zone, 'null') using errcode = '22023';
  end if;

  insert into identity.tenants (code, name, time_zone)
  values (btrim(p_code), btrim(p_name), p_time_zone)
  returning id into v_tenant;

  -- default branch inherits the tenant zone (no override)
  insert into identity.branches (tenant_id, code, name, timezone_override)
  values (v_tenant, coalesce(nullif(btrim(p_branch_code), ''), 'main'), coalesce(nullif(btrim(p_branch_name), ''), 'Main'), null)
  returning id into v_branch;

  if p_admin_email is not null and length(btrim(p_admin_email)) > 0 then
    select u.id, u.email into v_user, v_email
    from auth.users u where lower(u.email) = lower(btrim(p_admin_email))
    order by u.id limit 1;
    if v_user is not null then
      insert into identity.user_profiles (id, email) values (v_user, v_email) on conflict (id) do nothing;
      -- consent model: the first admin is INVITED and accepts like any other member
      insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
      values (v_tenant, v_user, null, 'tenant_admin', 'invited');
    end if;
  end if;

  return v_tenant;
end;
$$;
revoke all on function identity.create_tenant(text, text, text, text, text, text) from public, anon;
grant execute on function identity.create_tenant(text, text, text, text, text, text) to authenticated, service_role;
