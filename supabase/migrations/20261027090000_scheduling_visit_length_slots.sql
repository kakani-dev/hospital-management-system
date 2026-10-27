-- cross-schema: approved (no new cross-schema reads; same identity.* helpers as 20261022150000:
-- current_tenant_ids, branch_exists_v1, can_access_branch, branch_time_zone_v1, has_tenant_permission.)
-- Visit-length aware slots (#98 and the near-midnight e2e failure).
-- 1. appointment.available_slots_v2 takes the visit length and only returns starts whose whole visit fits
--    the working window and does not overlap a live booking. slot_end = start + visit length.
--    available_slots keeps its signature and calls v2 with the slot length (old behaviour, plus 2.).
-- 2. A visit ending exactly at local midnight is inside a window ending at 24:00 (#98): the old checks
--    compared clock times on one date, so 00:00 next day was "outside working hours".
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function appointment.available_slots_v2(
  p_tenant_id uuid, p_branch_id uuid, p_from date, p_to date, p_practitioner_id uuid default null, p_duration_minutes integer default null)
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
  if p_duration_minutes is not null and (p_duration_minutes < 5 or p_duration_minutes > 480) then
    raise exception 'invalid duration (5 to 480 minutes)' using errcode = '22023';
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
    -- Starts step by the schedule's slot length; the booking lasts the visit length (default: one slot)
    -- and must end by the window end. A window end of 24:00 or 00:00 means local midnight.
    select windows.practitioner_id, coalesce(p_duration_minutes, windows.slot_minutes) as minutes,
           (windows.day + windows.start_time) + make_interval(mins => k * windows.slot_minutes) as l_start,
           windows.day + windows.start_time
             + (windows.end_time - windows.start_time)
             + case when windows.end_time <= windows.start_time then interval '1 day' else interval '0' end as l_window_end
    from windows
    cross join lateral generate_series(
      0, (floor(extract(epoch from (windows.end_time - windows.start_time
            + case when windows.end_time <= windows.start_time then interval '1 day' else interval '0' end))
            / 60 / windows.slot_minutes))::int - 1) k
  ), slots as (
    select ls.practitioner_id,
           ls.l_start at time zone v_tz as s_start,
           (ls.l_start at time zone v_tz) + make_interval(mins => ls.minutes) as s_end,
           ls.l_start
    from local_slots ls
    where ls.l_start + make_interval(mins => ls.minutes) <= ls.l_window_end
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

create or replace function appointment.available_slots(p_tenant_id uuid, p_branch_id uuid, p_from date, p_to date, p_practitioner_id uuid default null)
returns table (practitioner_id uuid, branch_id uuid, slot_start timestamptz, slot_end timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select * from appointment.available_slots_v2(p_tenant_id, p_branch_id, p_from, p_to, p_practitioner_id, null);
$$;

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
         and v_ls::time >= o.start_time
         and v_le - v_day <= o.end_time - time '00:00'
                             + case when o.end_time <= o.start_time then interval '1 day' else interval '0' end) then
      raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
    end if;
    return;
  end if;
  if not exists (
      select 1 from appointment.schedules s
       where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.practitioner_id = p_practitioner_id
         and s.is_active and not s.is_deleted
         and s.weekday = extract(isodow from v_ls)
         and s.valid_from <= v_ls::date and (s.valid_to is null or s.valid_to >= v_ls::date)
         and v_ls::time >= s.start_time
         and v_le - v_day <= s.end_time - time '00:00'
                             + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) then
    raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
  end if;
end;
$$;

revoke all on function appointment.available_slots_v2(uuid, uuid, date, date, uuid, integer) from public, anon;
grant execute on function appointment.available_slots_v2(uuid, uuid, date, date, uuid, integer) to authenticated, service_role, hms_svc_scheduling;
