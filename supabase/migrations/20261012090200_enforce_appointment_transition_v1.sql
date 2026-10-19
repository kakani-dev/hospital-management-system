-- =============================================================================
-- DB re-review of PR #4 (R3): appointment.enforce_appointment_transition() no longer reads
-- patient.patients; it calls the published patient.patient_exists_v1() (single NOT is_deleted
-- predicate, review S5). The original lives in 20261010090100_appointment_schema.sql and is NOT
-- edited. A booked appointment moved to another patient gets the same check.
-- (R5, the zone-change confirmation, is part of 20261012090100_tenant_time_zone.sql.)
-- =============================================================================

set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- --------------------------------------------------------------------- R3 ----
create or replace function appointment.enforce_appointment_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_via_checkin boolean;
  v_via_queue   boolean;
  v_ok          boolean;
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'booked' then
      raise exception 'invalid_transition:new->%', new.status using errcode = '23514';
    end if;
    new.checked_in_at := null; new.started_at := null; new.completed_at := null; new.cancelled_at := null;
    -- 404-not-403: referenced rows of another tenant look unknown (P0002). Runs before RLS and the
    -- composite FKs (23503 backstop). Same-tenant branch without access is left to RLS (42501).
    perform appointment.assert_tenant_refs(new.tenant_id, new.branch_id);
    -- cross-schema: approved (published v1, DB review B2 / re-review R3)
    if not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
      raise exception 'patient not found' using errcode = 'P0002';
    end if;
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
    return new;
  end if;

  -- UPDATE
  -- lifecycle timestamps are trigger-owned
  new.checked_in_at := old.checked_in_at; new.started_at := old.started_at;
  new.completed_at := old.completed_at;   new.cancelled_at := old.cancelled_at;

  if old.status <> 'booked' and (
       new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
       or new.practitioner_id is distinct from old.practitioner_id or new.patient_id is distinct from old.patient_id
       or new.branch_id is distinct from old.branch_id) then
    raise exception 'invalid_transition:reschedule_not_booked' using errcode = '23514';
  end if;

  -- a booked appointment moved to another patient: same rule as INSERT
  if new.patient_id is distinct from old.patient_id
     and not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if new.practitioner_id is distinct from old.practitioner_id then
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  v_via_checkin := coalesce(current_setting('appointment.check_in', true), '') = old.id::text;
  v_via_queue   := coalesce(current_setting('appointment.queue_sync', true), '') = old.id::text;

  v_ok := case
    when old.status = 'booked' and new.status = 'checked_in' then v_via_checkin
    when old.status = 'booked' and new.status = 'cancelled' then true
    when old.status = 'booked' and new.status = 'no_show' then now() >= old.starts_at
    when old.status = 'checked_in' and new.status in ('in_consultation', 'cancelled') then true
    when old.status = 'in_consultation' and new.status = 'completed' then true
    when old.status = 'in_consultation' and new.status = 'cancelled' then v_via_queue  -- queue entry cancelled mid-consult
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', old.status, new.status using errcode = '23514';
  end if;

  -- clinical progress (in_consultation / completed) is for doctor / nurse / tenant_admin,
  -- or the queue RPC (which checks its own roles)
  if new.status in ('in_consultation', 'completed') and not v_via_queue and auth.uid() is not null
     and not identity.has_tenant_role(new.tenant_id, array['tenant_admin', 'doctor', 'nurse']) then
    raise exception 'not permitted to move an appointment to %', new.status using errcode = '42501';
  end if;

  case new.status
    when 'checked_in' then new.checked_in_at := now();
    when 'in_consultation' then new.started_at := now();
    when 'completed' then new.completed_at := now();
    when 'cancelled' then new.cancelled_at := now();
    else null;
  end case;
  return new;
end;
$$;
revoke all on function appointment.enforce_appointment_transition() from public;
