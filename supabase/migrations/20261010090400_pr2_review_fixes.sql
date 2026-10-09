-- =============================================================================
-- Sprint 2 / Migration 15: PR #2 review fixes (MAJ-1, MIN-3).
--
-- MAJ-1  Cancelling (or no-show-ing) an appointment that is already in the OPD queue now
--        cancels its active queue entry, so the board and the patient-delete check
--        (soft_delete_patient -> 55000 on an active entry) stay consistent with the appointment.
--        Direction appointment -> queue. The opposite direction (queue -> appointment) stays in
--        appointment.set_queue_status(). No recursion: set_queue_status() closes the queue entry
--        BEFORE it updates the appointment, so when this trigger fires from that path there is no
--        active entry left and it is a no-op. Queue-entry triggers never write appointments.
--
-- MIN-3  patients_update_registry_writers: the row filter (USING) now also requires access to the
--        patient's CURRENT registered branch; WITH CHECK already requires access to the NEW branch.
--        A branch-scoped writer can therefore neither edit another branch's patient nor move one
--        into their own branch. Tenant admins (all branches) are unaffected.
-- =============================================================================

-- ------------------------------------------------------------------ MAJ-1 ----
create or replace function appointment.cancel_queue_entry_for_appointment()
returns trigger
language plpgsql
security definer   -- clients have no DML on queue_entries; this is the owner-only sync path
set search_path = ''
as $$
begin
  update appointment.queue_entries q
     set status = 'cancelled',
         cancelled_at = now()
   where q.tenant_id = new.tenant_id
     and q.appointment_id = new.id
     and q.status in ('waiting', 'in_consultation');
  return null;
end;
$$;
revoke all on function appointment.cancel_queue_entry_for_appointment() from public, anon, authenticated;
comment on function appointment.cancel_queue_entry_for_appointment() is
  'AFTER UPDATE trigger: an appointment leaving the queue states (checked_in / in_consultation) for '
  'cancelled / no_show cancels its active OPD queue entry. Not callable by clients.';

create trigger appointments_cancel_queue_entry
  after update of status on appointment.appointments
  for each row
  when (old.status in ('checked_in', 'in_consultation') and new.status in ('cancelled', 'no_show'))
  execute function appointment.cancel_queue_entry_for_appointment();

-- ------------------------------------------------------------------ MIN-3 ----
drop policy if exists patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (
    deleted_at is null
    and identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
    and identity.can_access_branch(tenant_id, registered_branch_id)
  )
  with check (
    identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
    and identity.can_access_branch(tenant_id, registered_branch_id)
  );
