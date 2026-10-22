-- cross-schema: approved (FKs to identity.tenants/branches; reads zones only via identity.branch_time_zone_v1
-- and identity.branch_local_date_v1. No new _v1. Travel buffer lives in appointment.tenant_settings so
-- scheduling does not read identity.tenants.)
-- A practitioner is tenant-scoped and may work at many branches. Weekly hours stay on appointment.schedules
-- (valid_from/valid_to are the effective dates) but overlap is absolute time, not wall-clock on the same
-- weekday. Date overrides replace the weekly template for one branch-local day. Existing schedule rows are
-- not rewritten; the new rule applies to future writes.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- membership ----
create table appointment.practitioner_branches (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references identity.tenants (id) on delete restrict,
  practitioner_id        uuid not null,
  branch_id              uuid not null,
  is_active              boolean not null default true,
  consultation_room      text,
  consultation_fee_cents integer,
  created_on             timestamptz not null default now(),
  created_by             uuid not null,
  updated_on             timestamptz not null default now(),
  updated_by             uuid not null,
  is_deleted             boolean not null default false,
  constraint practitioner_branches_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete cascade,
  constraint practitioner_branches_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint practitioner_branches_tenant_id_id_key unique (tenant_id, id),
  constraint practitioner_branches_room_len check (consultation_room is null or length(btrim(consultation_room)) between 1 and 80),
  constraint practitioner_branches_fee_nonneg check (consultation_fee_cents is null or consultation_fee_cents >= 0)
);
create unique index practitioner_branches_live_key
  on appointment.practitioner_branches (tenant_id, practitioner_id, branch_id) where not is_deleted;
comment on table appointment.practitioner_branches is
  'Branches a practitioner works at. Weekly hours (appointment.schedules) require an active row.';

-- --------------------------------------------------------------- day overrides ----
create table appointment.schedule_overrides (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  practitioner_id  uuid not null,
  branch_id        uuid not null,
  override_date    date not null,
  is_leave         boolean not null default false,
  start_time       time,
  end_time         time,
  slot_minutes     smallint,
  is_active        boolean not null default true,
  during           tstzrange,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint schedule_overrides_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete cascade,
  constraint schedule_overrides_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint schedule_overrides_tenant_id_id_key unique (tenant_id, id),
  constraint schedule_overrides_shape check (
    (is_leave and start_time is null and end_time is null and slot_minutes is null)
    or (not is_leave and start_time < end_time and slot_minutes between 5 and 240))
);
create unique index schedule_overrides_live_key
  on appointment.schedule_overrides (tenant_id, practitioner_id, branch_id, override_date) where not is_deleted;
-- One absolute window per practitioner. Leave rows have during null and are excluded.
alter table appointment.schedule_overrides add constraint schedule_overrides_no_overlap exclude using gist (
  tenant_id with =,
  practitioner_id with =,
  during with &&
) where (during is not null and is_active and not is_deleted);
comment on table appointment.schedule_overrides is
  'One branch-local day that replaces the weekly template: leave (no slots) or a replacement window. during is absolute time.';

-- ---------------------------------------------------------------- travel buffer ----
create table appointment.tenant_settings (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references identity.tenants (id) on delete restrict,
  travel_buffer_minutes   smallint not null default 0,
  created_on              timestamptz not null default now(),
  created_by              uuid not null,
  updated_on              timestamptz not null default now(),
  updated_by              uuid not null,
  is_deleted              boolean not null default false,
  constraint tenant_settings_tenant_key unique (tenant_id),
  constraint tenant_settings_buffer_range check (travel_buffer_minutes between 0 and 180)
);
comment on table appointment.tenant_settings is
  'Per-tenant scheduling settings. travel_buffer_minutes (default 0) is the gap required between commitments at different branches. A missing row means 0.';

-- Distinct (practitioner, branch) pairs already implied by weekly hours become memberships.
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id, is_active, created_by, updated_by)
select s.tenant_id, s.practitioner_id, s.branch_id, bool_or(s.is_active and not s.is_deleted),
       '00000000-0000-4000-8000-00000000005e', '00000000-0000-4000-8000-00000000005e'
from appointment.schedules s
group by s.tenant_id, s.practitioner_id, s.branch_id;

insert into appointment.tenant_settings (tenant_id, travel_buffer_minutes, created_by, updated_by)
select t.id, 0, '00000000-0000-4000-8000-00000000005e', '00000000-0000-4000-8000-00000000005e'
from identity.tenants t;

-- Wall-clock exclusion rejects the same hours in two zones and misses absolute overlaps on different
-- local weekdays. The commitment triggers below are the replacement (weekly recurrence is not one range).
alter table appointment.schedules drop constraint schedules_no_overlap;

-- --------------------------------------------------------------------- helpers ----
create or replace function appointment.travel_buffer(p_tenant_id uuid)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select make_interval(mins => coalesce((
    select s.travel_buffer_minutes from appointment.tenant_settings s
     where s.tenant_id = p_tenant_id and not s.is_deleted
     limit 1), 0))
$$;

create or replace function appointment.local_window(p_day date, p_start time, p_end time, p_zone text)
returns tstzrange
language sql
stable
set search_path = ''
as $$
  select case
    when p_day is null or p_start is null or p_end is null or p_start >= p_end or p_zone is null then null
    else tstzrange((p_day + p_start) at time zone p_zone, (p_day + p_end) at time zone p_zone, '[)')
  end
$$;

-- Same branch: half-open overlap only (back-to-back stays valid). Different branches: also the gap
-- shorter than the travel buffer. Expanding only one side would not be symmetric.
create or replace function appointment.ranges_conflict(
  a tstzrange, a_branch uuid, b tstzrange, b_branch uuid, buffer interval)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select a is not null and b is not null and case
    when a_branch is not distinct from b_branch then a && b
    when buffer is null or buffer <= interval '0' then a && b
    else a && b
      or (upper(a) <= lower(b) and lower(b) - upper(a) < buffer)
      or (upper(b) <= lower(a) and lower(a) - upper(b) < buffer)
  end
$$;

revoke all on function appointment.travel_buffer(uuid) from public, anon, authenticated;
revoke all on function appointment.local_window(date, time, time, text) from public, anon, authenticated;
revoke all on function appointment.ranges_conflict(tstzrange, uuid, tstzrange, uuid, interval) from public, anon, authenticated;

-- A weekly template conflicts with other templates (any branch), other-branch hour overrides, and
-- other-branch blocking appointments. Same-branch overrides replace the template; same-branch
-- appointments sit inside it. Compared over the validity intersection, capped at 366 days from the
-- later start so one DST year is covered. Dates within ±1 day: a Sunday in one zone can meet a Monday
-- in another.
create or replace function appointment.enforce_schedule_commitment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zone text;
  v_buffer interval;
begin
  if new.is_deleted or not new.is_active then
    return new;
  end if;
  -- Let schedules_time_order (23514) win over membership / overlap.
  if new.start_time >= new.end_time or new.valid_to < new.valid_from then
    return new;
  end if;
  if not exists (
    select 1 from appointment.practitioners p
     where p.tenant_id = new.tenant_id and p.id = new.practitioner_id and not p.is_deleted) then
    return new; -- schedules_refs or the composite FK reports P0002 / 23503
  end if;
  if not exists (
    select 1 from appointment.practitioner_branches m
     where m.tenant_id = new.tenant_id and m.practitioner_id = new.practitioner_id
       and m.branch_id = new.branch_id and m.is_active and not m.is_deleted) then
    raise exception 'practitioner_not_at_branch: the doctor does not work at this branch' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.practitioner_id::text, 0));
  v_zone := identity.branch_time_zone_v1(new.branch_id);
  v_buffer := appointment.travel_buffer(new.tenant_id);

  if exists (
    select 1
      from appointment.schedules o
      cross join lateral (
        select greatest(new.valid_from, o.valid_from) as d0,
               least(coalesce(new.valid_to, 'infinity'::date), coalesce(o.valid_to, 'infinity'::date),
                     greatest(new.valid_from, o.valid_from) + 366) as d1
      ) win
      cross join lateral generate_series(win.d0::timestamp, win.d1::timestamp, interval '1 day') g(day)
      cross join lateral (
        select od::date as day from generate_series((g.day::date - 1)::timestamp, (g.day::date + 1)::timestamp, interval '1 day') od
      ) other
     where win.d1 >= win.d0
       and o.tenant_id = new.tenant_id and o.practitioner_id = new.practitioner_id
       and o.id is distinct from new.id and o.is_active and not o.is_deleted
       and extract(isodow from g.day::date) = new.weekday
       and extract(isodow from other.day) = o.weekday
       and other.day >= o.valid_from and (o.valid_to is null or other.day <= o.valid_to)
       and appointment.ranges_conflict(
             appointment.local_window(g.day::date, new.start_time, new.end_time, v_zone), new.branch_id,
             appointment.local_window(other.day, o.start_time, o.end_time, identity.branch_time_zone_v1(o.branch_id)),
             o.branch_id,
             case when o.branch_id = new.branch_id then interval '0' else v_buffer end)
  ) then
    raise exception 'schedule_overlap: the doctor is already scheduled at that time' using errcode = '23P01';
  end if;

  if exists (
    select 1
      from appointment.schedule_overrides o
      cross join lateral generate_series(
        greatest(new.valid_from, o.override_date - 1)::timestamp,
        least(coalesce(new.valid_to, o.override_date), o.override_date, new.valid_from + 366)::timestamp,
        interval '1 day') g(day)
     where o.tenant_id = new.tenant_id and o.practitioner_id = new.practitioner_id
       and o.branch_id <> new.branch_id and o.is_active and not o.is_deleted and not o.is_leave
       and o.during is not null
       and o.override_date between new.valid_from - 1 and coalesce(new.valid_to, new.valid_from + 366) + 1
       and extract(isodow from g.day::date) = new.weekday
       and g.day::date >= new.valid_from and (new.valid_to is null or g.day::date <= new.valid_to)
       and appointment.ranges_conflict(
             appointment.local_window(g.day::date, new.start_time, new.end_time, v_zone), new.branch_id,
             o.during, o.branch_id, v_buffer)
  ) then
    raise exception 'schedule_overlap: the doctor is already scheduled at that time' using errcode = '23P01';
  end if;

  if exists (
    select 1
      from appointment.appointments a
      cross join lateral generate_series(
        greatest(new.valid_from, ((a.starts_at at time zone v_zone)::date - 1))::timestamp,
        least(coalesce(new.valid_to, (a.starts_at at time zone v_zone)::date),
              (a.starts_at at time zone v_zone)::date, new.valid_from + 366)::timestamp,
        interval '1 day') g(day)
     where a.tenant_id = new.tenant_id and a.practitioner_id = new.practitioner_id
       and a.branch_id <> new.branch_id
       and a.status in ('booked', 'checked_in', 'in_consultation', 'completed')
       and a.starts_at < ((coalesce(new.valid_to, new.valid_from + 366) + 2)::timestamp at time zone v_zone)
       and a.ends_at > (new.valid_from::timestamp at time zone v_zone)
       and extract(isodow from g.day::date) = new.weekday
       and g.day::date >= new.valid_from and (new.valid_to is null or g.day::date <= new.valid_to)
       and appointment.ranges_conflict(
             appointment.local_window(g.day::date, new.start_time, new.end_time, v_zone), new.branch_id,
             tstzrange(a.starts_at, a.ends_at, '[)'), a.branch_id, v_buffer)
  ) then
    raise exception 'schedule_overlap: the doctor is already scheduled at that time' using errcode = '23P01';
  end if;

  return new;
end;
$$;
revoke all on function appointment.enforce_schedule_commitment() from public, anon, authenticated;
create trigger z_schedules_commitment before insert or update on appointment.schedules
  for each row execute function appointment.enforce_schedule_commitment();

create or replace function appointment.enforce_override_commitment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zone text;
  v_buffer interval;
begin
  if new.is_deleted or not new.is_active then
    new.during := null;
    return new;
  end if;
  if not new.is_leave and (new.start_time is null or new.end_time is null or new.start_time >= new.end_time) then
    new.during := null;
    return new; -- schedule_overrides_shape raises 23514
  end if;
  if not exists (
    select 1 from appointment.practitioners p
     where p.tenant_id = new.tenant_id and p.id = new.practitioner_id and not p.is_deleted) then
    return new;
  end if;
  if not exists (
    select 1 from appointment.practitioner_branches m
     where m.tenant_id = new.tenant_id and m.practitioner_id = new.practitioner_id
       and m.branch_id = new.branch_id and m.is_active and not m.is_deleted) then
    raise exception 'practitioner_not_at_branch: the doctor does not work at this branch' using errcode = '22023';
  end if;
  if new.is_leave then
    new.during := null;
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.practitioner_id::text, 0));
  v_zone := identity.branch_time_zone_v1(new.branch_id);
  new.during := appointment.local_window(new.override_date, new.start_time, new.end_time, v_zone);
  v_buffer := appointment.travel_buffer(new.tenant_id);

  if exists (
    select 1
      from appointment.schedules s
      cross join lateral (
        select od::date as day
          from generate_series((new.override_date - 1)::timestamp, (new.override_date + 1)::timestamp, interval '1 day') od
      ) other
     where s.tenant_id = new.tenant_id and s.practitioner_id = new.practitioner_id
       and s.branch_id <> new.branch_id and s.is_active and not s.is_deleted
       and extract(isodow from other.day) = s.weekday
       and other.day >= s.valid_from and (s.valid_to is null or other.day <= s.valid_to)
       and appointment.ranges_conflict(
             new.during, new.branch_id,
             appointment.local_window(other.day, s.start_time, s.end_time, identity.branch_time_zone_v1(s.branch_id)),
             s.branch_id, v_buffer)
  ) or exists (
    select 1 from appointment.schedule_overrides o
     where o.tenant_id = new.tenant_id and o.practitioner_id = new.practitioner_id
       and o.id is distinct from new.id and o.branch_id <> new.branch_id
       and o.is_active and not o.is_deleted and o.during is not null
       and appointment.ranges_conflict(new.during, new.branch_id, o.during, o.branch_id, v_buffer)
  ) or exists (
    select 1 from appointment.appointments a
     where a.tenant_id = new.tenant_id and a.practitioner_id = new.practitioner_id
       and a.branch_id <> new.branch_id
       and a.status in ('booked', 'checked_in', 'in_consultation', 'completed')
       and appointment.ranges_conflict(new.during, new.branch_id, tstzrange(a.starts_at, a.ends_at, '[)'), a.branch_id, v_buffer)
  ) then
    raise exception 'schedule_overlap: the doctor is already scheduled at that time' using errcode = '23P01';
  end if;
  return new;
end;
$$;
revoke all on function appointment.enforce_override_commitment() from public, anon, authenticated;
create trigger z_schedule_overrides_commitment before insert or update on appointment.schedule_overrides
  for each row execute function appointment.enforce_override_commitment();

-- Blocking appointments must belong to a branch the doctor works at, and must not land inside another
-- branch's hours, hour-override, or (with the travel buffer) another branch's appointment.
-- Same-branch appointment overlap stays appointments_no_practitioner_overlap. Same-branch weekly hours
-- are not a conflict: the slot is inside them. Runs after appointments_status_machine (name order).
create or replace function appointment.enforce_appointment_commitment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_during tstzrange;
  v_buffer interval;
begin
  if new.status not in ('booked', 'checked_in', 'in_consultation', 'completed') then
    return new;
  end if;
  if new.ends_at <= new.starts_at then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and old.status in ('booked', 'checked_in', 'in_consultation', 'completed')
     and new.starts_at is not distinct from old.starts_at
     and new.ends_at is not distinct from old.ends_at
     and new.practitioner_id is not distinct from old.practitioner_id
     and new.branch_id is not distinct from old.branch_id then
    return new;
  end if;
  if not exists (
    select 1 from appointment.practitioners p
     where p.tenant_id = new.tenant_id and p.id = new.practitioner_id and not p.is_deleted) then
    return new;
  end if;
  if not exists (
    select 1 from appointment.practitioner_branches m
     where m.tenant_id = new.tenant_id and m.practitioner_id = new.practitioner_id
       and m.branch_id = new.branch_id and m.is_active and not m.is_deleted) then
    raise exception 'practitioner_not_at_branch: the doctor does not work at this branch' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.practitioner_id::text, 0));
  v_during := tstzrange(new.starts_at, new.ends_at, '[)');
  v_buffer := appointment.travel_buffer(new.tenant_id);

  if exists (
    select 1
      from appointment.schedules s
      cross join lateral (
        select od::date as day
          from generate_series(
            (((new.starts_at at time zone identity.branch_time_zone_v1(s.branch_id))::date - 1)::timestamp),
            (((new.ends_at at time zone identity.branch_time_zone_v1(s.branch_id))::date + 1)::timestamp),
            interval '1 day') od
      ) other
     where s.tenant_id = new.tenant_id and s.practitioner_id = new.practitioner_id
       and s.branch_id <> new.branch_id and s.is_active and not s.is_deleted
       and extract(isodow from other.day) = s.weekday
       and other.day >= s.valid_from and (s.valid_to is null or other.day <= s.valid_to)
       and appointment.ranges_conflict(
             v_during, new.branch_id,
             appointment.local_window(other.day, s.start_time, s.end_time, identity.branch_time_zone_v1(s.branch_id)),
             s.branch_id, v_buffer)
  ) or exists (
    select 1 from appointment.schedule_overrides o
     where o.tenant_id = new.tenant_id and o.practitioner_id = new.practitioner_id
       and o.branch_id <> new.branch_id and o.is_active and not o.is_deleted and not o.is_leave
       and o.during is not null
       and appointment.ranges_conflict(v_during, new.branch_id, o.during, o.branch_id, v_buffer)
  ) or exists (
    select 1 from appointment.appointments a
     where a.tenant_id = new.tenant_id and a.practitioner_id = new.practitioner_id
       and a.id is distinct from new.id and a.branch_id <> new.branch_id
       and a.status in ('booked', 'checked_in', 'in_consultation', 'completed')
       and appointment.ranges_conflict(v_during, new.branch_id, tstzrange(a.starts_at, a.ends_at, '[)'), a.branch_id, v_buffer)
  ) then
    raise exception 'schedule_overlap: the doctor is already scheduled at that time' using errcode = '23P01';
  end if;

  return new;
end;
$$;
revoke all on function appointment.enforce_appointment_commitment() from public, anon, authenticated;
create trigger z_appointments_commitment before insert or update on appointment.appointments
  for each row execute function appointment.enforce_appointment_commitment();

-- ------------------------------------------------------------ bookable window ----
create or replace function appointment.assert_bookable_window_v2(
  p_tenant_id uuid, p_branch_id uuid, p_practitioner_id uuid, p_starts timestamptz, p_ends timestamptz, p_override boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_zone text;
  v_ls timestamp;
  v_le timestamp;
  v_day date;
begin
  perform appointment.assert_bookable_window(p_tenant_id, p_branch_id, p_practitioner_id, p_starts, p_ends);
  if not exists (select 1 from appointment.practitioners p
                  where p.tenant_id = p_tenant_id and p.id = p_practitioner_id and not p.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from appointment.practitioner_branches m
     where m.tenant_id = p_tenant_id and m.practitioner_id = p_practitioner_id
       and m.branch_id = p_branch_id and m.is_active and not m.is_deleted) then
    raise exception 'practitioner_not_at_branch: the doctor does not work at this branch' using errcode = '22023';
  end if;
  if coalesce(p_override, false) then
    if not identity.has_tenant_permission(p_tenant_id, 'appointments.override_hours') then
      raise exception 'only admins can book outside working hours' using errcode = '42501';
    end if;
    return; -- this branch's hours are waived; the appointment trigger still rejects another branch's commitment
  end if;
  v_zone := identity.branch_time_zone_v1(p_branch_id);
  v_ls := p_starts at time zone v_zone;
  v_le := p_ends at time zone v_zone;
  v_day := v_ls::date;
  if exists (
    select 1 from appointment.schedule_overrides o
     where o.tenant_id = p_tenant_id and o.branch_id = p_branch_id and o.practitioner_id = p_practitioner_id
       and o.override_date = v_day and o.is_active and not o.is_deleted and o.is_leave) then
    raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
  end if;
  if exists (
    select 1 from appointment.schedule_overrides o
     where o.tenant_id = p_tenant_id and o.branch_id = p_branch_id and o.practitioner_id = p_practitioner_id
       and o.override_date = v_day and o.is_active and not o.is_deleted and not o.is_leave) then
    if not exists (
      select 1 from appointment.schedule_overrides o
       where o.tenant_id = p_tenant_id and o.branch_id = p_branch_id and o.practitioner_id = p_practitioner_id
         and o.override_date = v_day and o.is_active and not o.is_deleted and not o.is_leave
         and v_ls::date = v_le::date and v_ls::time >= o.start_time and v_le::time <= o.end_time) then
      raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
    end if;
    return;
  end if;
  if not exists (
      select 1 from appointment.schedules s
       where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.practitioner_id = p_practitioner_id
         and s.is_active and not s.is_deleted
         and s.weekday = extract(isodow from v_ls)
         and v_ls::date = v_le::date
         and s.valid_from <= v_ls::date and (s.valid_to is null or s.valid_to >= v_ls::date)
         and v_ls::time >= s.start_time and v_le::time <= s.end_time) then
    raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
  end if;
end;
$$;

-- ----------------------------------------------------------------- free slots ----
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
  v_tz := identity.branch_time_zone_v1(p_branch_id);

  return query
  with days as (
    select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ), windows as (
    select s.practitioner_id, s.start_time, s.end_time, s.slot_minutes, days.day
    from appointment.schedules s
    join appointment.practitioners pr on pr.tenant_id = s.tenant_id and pr.id = s.practitioner_id
                                     and pr.is_active and not pr.is_deleted
    join appointment.practitioner_branches m on m.tenant_id = s.tenant_id and m.practitioner_id = s.practitioner_id
                                            and m.branch_id = s.branch_id and m.is_active and not m.is_deleted
    join days on extract(isodow from days.day) = s.weekday
             and days.day >= s.valid_from and (s.valid_to is null or days.day <= s.valid_to)
    where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.is_active and not s.is_deleted
      and (p_practitioner_id is null or s.practitioner_id = p_practitioner_id)
      and not exists (
        select 1 from appointment.schedule_overrides o
         where o.tenant_id = s.tenant_id and o.practitioner_id = s.practitioner_id and o.branch_id = s.branch_id
           and o.override_date = days.day and o.is_active and not o.is_deleted)
    union all
    select o.practitioner_id, o.start_time, o.end_time, o.slot_minutes, o.override_date
    from appointment.schedule_overrides o
    join appointment.practitioners pr on pr.tenant_id = o.tenant_id and pr.id = o.practitioner_id
                                     and pr.is_active and not pr.is_deleted
    join appointment.practitioner_branches m on m.tenant_id = o.tenant_id and m.practitioner_id = o.practitioner_id
                                            and m.branch_id = o.branch_id and m.is_active and not m.is_deleted
    where o.tenant_id = p_tenant_id and o.branch_id = p_branch_id
      and o.override_date between p_from and p_to
      and o.is_active and not o.is_deleted and not o.is_leave
      and (p_practitioner_id is null or o.practitioner_id = p_practitioner_id)
  ), local_slots as (
    select windows.practitioner_id, windows.slot_minutes,
           (windows.day + windows.start_time) + make_interval(mins => k * windows.slot_minutes) as l_start
    from windows
    cross join lateral generate_series(
      0, (floor(extract(epoch from (windows.end_time - windows.start_time)) / 60 / windows.slot_minutes))::int - 1) k
  ), slots as (
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

-- Walk-in with a named doctor requires an active membership at that branch. A null doctor stays allowed.
create or replace function appointment.check_in_walk_in(p_branch_id uuid, p_patient_id uuid, p_practitioner_id uuid default null)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  v_tenant := identity.branch_tenant_id_v1(p_branch_id);
  if v_tenant is null or v_tenant not in (select identity.current_tenant_ids()) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_tenant, array['tenant_admin', 'receptionist', 'nurse'])
     or not identity.can_access_branch(v_tenant, p_branch_id) then
    raise exception 'not permitted to check in at this branch' using errcode = '42501';
  end if;

  if not patient.patient_exists_v1(v_tenant, p_patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if p_practitioner_id is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = v_tenant and pr.id = p_practitioner_id and pr.is_active and not pr.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if p_practitioner_id is not null and not exists (
       select 1 from appointment.practitioner_branches m
        where m.tenant_id = v_tenant and m.practitioner_id = p_practitioner_id
          and m.branch_id = p_branch_id and m.is_active and not m.is_deleted) then
    raise exception 'practitioner_not_at_branch: the doctor does not work at this branch' using errcode = '22023';
  end if;

  return query select * from appointment.issue_queue_token(v_tenant, p_branch_id, p_patient_id, null, p_practitioner_id);
end;
$$;

-- ------------------------------------------------------------------------- RLS ----
alter table appointment.practitioner_branches enable row level security;
alter table appointment.schedule_overrides    enable row level security;
alter table appointment.tenant_settings       enable row level security;

revoke all on appointment.practitioner_branches, appointment.schedule_overrides, appointment.tenant_settings
  from public, anon, authenticated;

create policy practitioner_branches_select_member on appointment.practitioner_branches
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
create policy practitioner_branches_insert_admin on appointment.practitioner_branches
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));
create policy practitioner_branches_update_admin on appointment.practitioner_branches
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));

create policy schedule_overrides_select_member on appointment.schedule_overrides
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
create policy schedule_overrides_insert_admin on appointment.schedule_overrides
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));
create policy schedule_overrides_update_admin on appointment.schedule_overrides
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));

create policy tenant_settings_select_member on appointment.tenant_settings
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids()) and not is_deleted);
create policy tenant_settings_insert_admin on appointment.tenant_settings
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));
create policy tenant_settings_update_admin on appointment.tenant_settings
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

grant select on appointment.practitioner_branches, appointment.schedule_overrides, appointment.tenant_settings to authenticated;
grant insert (id, tenant_id, practitioner_id, branch_id, is_active, consultation_room, consultation_fee_cents)
  on appointment.practitioner_branches to authenticated;
grant update (is_active, consultation_room, consultation_fee_cents)
  on appointment.practitioner_branches to authenticated;
grant insert (id, tenant_id, practitioner_id, branch_id, override_date, is_leave, start_time, end_time, slot_minutes, is_active)
  on appointment.schedule_overrides to authenticated;
grant update (is_leave, start_time, end_time, slot_minutes, is_active)
  on appointment.schedule_overrides to authenticated;
grant insert (id, tenant_id, travel_buffer_minutes) on appointment.tenant_settings to authenticated;
grant update (travel_buffer_minutes) on appointment.tenant_settings to authenticated;
grant all on appointment.practitioner_branches, appointment.schedule_overrides, appointment.tenant_settings to service_role;

create trigger practitioner_branches_audit_columns before insert or update on appointment.practitioner_branches
  for each row execute function audit.stamp_audit_columns();
create trigger practitioner_branches_tenant_immutable before update on appointment.practitioner_branches
  for each row execute function audit.prevent_tenant_change();
create trigger practitioner_branches_audit_log after insert or update or delete on appointment.practitioner_branches
  for each row execute function audit.log_row_change();

create trigger schedule_overrides_audit_columns before insert or update on appointment.schedule_overrides
  for each row execute function audit.stamp_audit_columns();
create trigger schedule_overrides_tenant_immutable before update on appointment.schedule_overrides
  for each row execute function audit.prevent_tenant_change();
create trigger schedule_overrides_audit_log after insert or update or delete on appointment.schedule_overrides
  for each row execute function audit.log_row_change();

create trigger tenant_settings_audit_columns before insert or update on appointment.tenant_settings
  for each row execute function audit.stamp_audit_columns();
create trigger tenant_settings_tenant_immutable before update on appointment.tenant_settings
  for each row execute function audit.prevent_tenant_change();
create trigger tenant_settings_audit_log after insert or update or delete on appointment.tenant_settings
  for each row execute function audit.log_row_change();
