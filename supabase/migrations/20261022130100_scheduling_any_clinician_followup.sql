-- cross-schema: approved (insert policy calls identity.has_tenant_permission and identity.can_access_branch)
-- A clinician with appointments.book_followup_own may book a follow-up of any patient's earlier visit
-- in the hospital, at a branch they can access. The parent visit may be at another branch.
-- A fresh booking (no parent) stays forbidden. Queue, check-in and the visit's own branch are unchanged.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

drop policy appointments_insert_writers on appointment.appointments;
create policy appointments_insert_writers on appointment.appointments
  for insert to authenticated
  with check (identity.can_access_branch(tenant_id, branch_id)
              and (identity.has_tenant_permission(tenant_id, 'appointments.book')
                   or (identity.has_tenant_permission(tenant_id, 'appointments.book_followup_own')
                       and parent_appointment_id is not null)));

comment on policy appointments_insert_writers on appointment.appointments is
  'Book at a branch the caller can access, or (doctors) a follow-up of any earlier visit in the hospital. Fresh doctor bookings stay forbidden.';
