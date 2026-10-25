-- BUG-10: booking outside working hours requires a reason.
-- cross-schema: approved (the existing parent check calls identity.has_tenant_permission)
-- The reason is the appointment's existing reason column. The permission check stays first so a
-- receptionist who sets the flag is still rejected with 42501, before the reason is considered.
-- A later update of a row that already has hours_override does not demand a new reason.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function appointment.check_parent_appointment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent_patient uuid;
  v_reason text;
  v_turning_on boolean;
begin
  v_turning_on := new.hours_override and (tg_op = 'INSERT' or not old.hours_override);
  if tg_op = 'UPDATE' then
    if new.parent_appointment_id is distinct from old.parent_appointment_id then
      raise exception 'parent_appointment_id cannot change' using errcode = '22023';
    end if;
    if new.hours_override is distinct from old.hours_override and not new.hours_override then
      raise exception 'hours_override cannot be cleared' using errcode = '22023';
    end if;
    if v_turning_on and auth.uid() is not null
       and not identity.has_tenant_permission(new.tenant_id, 'appointments.override_hours') then
      raise exception 'only admins can book outside working hours' using errcode = '42501';
    end if;
  elsif new.hours_override and auth.uid() is not null
     and not identity.has_tenant_permission(new.tenant_id, 'appointments.override_hours') then
    raise exception 'only admins can book outside working hours' using errcode = '42501';
  end if;

  if v_turning_on then
    v_reason := btrim(new.reason);
    if v_reason is null or char_length(v_reason) < 1 or char_length(v_reason) > 500 then
      raise exception 'A reason is required when booking outside working hours.' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'UPDATE' or new.parent_appointment_id is null then
    return new;
  end if;

  select a.patient_id into v_parent_patient from appointment.appointments a
   where a.tenant_id = new.tenant_id and a.id = new.parent_appointment_id;
  if v_parent_patient is null then
    raise exception 'parent appointment not found' using errcode = 'P0002';
  end if;
  if v_parent_patient <> new.patient_id then
    raise exception 'follow_up_patient_mismatch: a follow-up must be for the same patient as the earlier visit' using errcode = '22023';
  end if;
  return new;
end;
$$;
