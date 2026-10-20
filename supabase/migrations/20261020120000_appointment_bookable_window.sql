-- Business-logic audit (2026-10-20): a booking or reschedule made through the API must not be
-- dated before the branch-local "today" (tenant zone unless the branch overrides it). Same-day
-- bookings stay allowed (a patient who has already arrived can be booked and checked in).
-- Whether bookings must also fall inside the practitioner's working hours is a product decision
-- (overbooking / extra slots) and is NOT enforced here. Called by the scheduling API; the trigger
-- is unchanged so trusted imports keep working. Existing rows are not touched.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function appointment.assert_bookable_window(
  p_tenant_id uuid, p_branch_id uuid, p_practitioner_id uuid, p_starts timestamptz, p_ends timestamptz)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if p_starts < (identity.branch_local_date_v1(p_branch_id)::timestamp at time zone identity.branch_time_zone_v1(p_branch_id)) then
    raise exception 'appointment_in_past: appointments cannot be booked for an earlier day' using errcode = '22023';
  end if;
end;
$$;
revoke all on function appointment.assert_bookable_window(uuid, uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function appointment.assert_bookable_window(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated;
