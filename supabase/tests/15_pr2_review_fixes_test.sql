-- PR #2 review fixes. Migration 20261010090400_pr2_review_fixes.sql.
--   MAJ-1: cancelling a checked-in appointment cancels its active OPD queue entry.
--   MIN-3: patients UPDATE policy also requires access to the patient's CURRENT branch.
begin;

select tests.as_superuser();
create temporary table t_ctx on commit drop as
  select identity.branch_local_date_v1(b.id) as today, identity.branch_time_zone_v1(b.id) as tz
  from identity.branches b where b.id = 'a1111111-0000-4000-8000-000000000001';
grant select on t_ctx to public;

-- Two of today's appointments at Alpha Main: Ravi (aa..02, no other bookings) and Kiran (aa..04).
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000c1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002',
       (today + time '00:05') at time zone tz, (today + time '00:20') at time zone tz from t_ctx;
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000c2', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004',
       (today + time '00:25') at time zone tz, (today + time '00:40') at time zone tz from t_ctx;
-- A doctor at Alpha Main and a receptionist scoped to Alpha East.
insert into auth.users (id, email, role, aud) values
  ('0a000000-0000-4000-8000-0000000000d5', 'doctor-main-15@alpha.example', 'authenticated', 'authenticated'),
  ('0a000000-0000-4000-8000-0000000000e5', 'reception-east-15@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000d5', 'a1111111-0000-4000-8000-000000000001', 'doctor', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e5', 'a1111111-0000-4000-8000-000000000002', 'receptionist', 'active');

-- ---------- MAJ-1: privileges / wiring ----------
select tests.ok(
  not has_function_privilege('authenticated', 'appointment.cancel_queue_entry_for_appointment()', 'execute')
  and not has_function_privilege('anon', 'appointment.cancel_queue_entry_for_appointment()', 'execute'),
  'MAJ-1: queue-cancel sync function is not callable by clients');
select tests.ok(
  exists (select 1 from pg_trigger t where t.tgrelid = 'appointment.appointments'::regclass
          and t.tgname = 'appointments_cancel_queue_entry' and not t.tgisinternal),
  'MAJ-1: appointments_cancel_queue_entry trigger is installed');

-- ---------- MAJ-1: check in, then cancel the appointment (exactly the API's UPDATE) ----------
select tests.authenticate_as('reception@alpha.example');
create temporary table t_q1 on commit drop as
  select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                     'aa000000-0000-4000-8000-000000000002', 'e1111111-0000-4000-8000-0000000000c1');
select tests.ok(
  (select status = 'waiting' from appointment.queue_entries where id = (select queue_entry_id from t_q1)),
  'MAJ-1 setup: checked-in appointment has a waiting queue entry');
select tests.ok(
  tests.affected_rows($$update appointment.appointments set status = 'cancelled', cancel_reason = 'patient left'
                        where id = 'e1111111-0000-4000-8000-0000000000c1'$$) = 1,
  'MAJ-1: receptionist cancels the checked-in appointment');
select tests.ok(
  (select q.status = 'cancelled' and q.cancelled_at is not null
   from appointment.queue_entries q where q.id = (select queue_entry_id from t_q1)),
  'MAJ-1: cancelling a checked-in appointment cancels its queue entry');
select tests.ok(
  not exists (select 1 from appointment.queue_entries q
              where q.branch_id = 'a1111111-0000-4000-8000-000000000001'
                and q.queue_date = (select today from t_ctx)
                and q.patient_id = 'aa000000-0000-4000-8000-000000000002'
                and q.status in ('waiting', 'in_consultation')),
  'MAJ-1: the patient is no longer active on today''s board');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'in_consultation')$$, (select queue_entry_id from t_q1)),
  '23514', 'MAJ-1: calling in the cancelled entry is an invalid transition (cancelled -> in_consultation)');

-- the patient can now be soft-deleted (no open appointment or queue entry left)
select tests.authenticate_as('admin@alpha.example');
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002', 'test: cancelled after check-in');
select tests.as_superuser();
select tests.ok(
  (select deleted_at is not null from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'MAJ-1: patient with a cancelled-after-check-in appointment can be soft-deleted');
select tests.ok(
  (select count(*) >= 2 from messaging.outbox o
   where o.aggregate_id = (select queue_entry_id from t_q1)),
  'MAJ-1: the sync goes through the normal queue triggers (outbox event for the queue entry)');

-- ---------- MAJ-1: no recursion with the queue -> appointment sync ----------
select tests.authenticate_as('reception@alpha.example');
create temporary table t_q2 on commit drop as
  select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                     'aa000000-0000-4000-8000-000000000004', 'e1111111-0000-4000-8000-0000000000c2');
select appointment.set_queue_status((select queue_entry_id from t_q2), 'cancelled');
select tests.ok(
  (select q.status = 'cancelled' and a.status = 'cancelled'
   from appointment.queue_entries q join appointment.appointments a on a.id = q.appointment_id
   where q.id = (select queue_entry_id from t_q2)),
  'MAJ-1: cancelling via the queue still cancels the appointment once (no recursion, no error)');
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from audit.audit_log l
   where l.table_name = 'queue_entries' and l.record_id = (select queue_entry_id from t_q2) and l.action = 'UPDATE'),
  'MAJ-1: queue-path cancel updates the queue entry exactly once');

-- in_consultation -> cancelled via the queue (doctor calls in, reception cancels): still one consistent cancel
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000c3', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001',
       (today + time '00:45') at time zone tz, (today + time '01:00') at time zone tz from t_ctx;
select tests.authenticate_as('reception@alpha.example');
create temporary table t_q3 on commit drop as
  select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                     'aa000000-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-0000000000c3');
select tests.as_superuser();
update appointment.practitioners set user_id = '0a000000-0000-4000-8000-0000000000d5'
 where id = 'c1111111-0000-4000-8000-000000000002';
select tests.authenticate_as('doctor-main-15@alpha.example');
select appointment.set_queue_status((select queue_entry_id from t_q3), 'in_consultation');
select tests.throws_ok(
  $$update appointment.appointments set status = 'cancelled' where id = 'e1111111-0000-4000-8000-0000000000c3'$$,
  '23514', 'MAJ-1: an in-consultation appointment still cannot be cancelled directly (only via the queue)');
select tests.authenticate_as('reception@alpha.example');
select appointment.set_queue_status((select queue_entry_id from t_q3), 'cancelled');
select tests.as_superuser();
select tests.ok(
  (select q.status = 'cancelled' and a.status = 'cancelled' and a.cancelled_at is not null
   from appointment.queue_entries q join appointment.appointments a on a.id = q.appointment_id
   where q.id = (select queue_entry_id from t_q3)),
  'MAJ-1: in_consultation -> cancelled via the queue keeps queue and appointment consistent');

-- ---------- chart edits are hospital-wide; another hospital stays invisible ----------
-- Meera (aa..03) is registered at Alpha East; reception@alpha.example is scoped to Alpha Main.
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Edited'
                        where id = 'aa000000-0000-4000-8000-000000000003'$$) = 1,
  'receptionist@Main can edit an East patient');
select tests.ok(
  tests.affected_rows($$update patient.patients set registered_branch_id = 'a1111111-0000-4000-8000-000000000001'
                        where id = 'aa000000-0000-4000-8000-000000000003'$$) = 1,
  'receptionist@Main can change the registered branch to another branch of this hospital');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Nope'
                        where id = 'bb000000-0000-4000-8000-000000000001'$$) = 0,
  'receptionist@Main cannot edit a Beta patient (0 rows)');

select tests.authenticate_as('lab@alpha.example');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Lab'
                        where id = 'aa000000-0000-4000-8000-000000000001'$$) = 0,
  'lab technician has no patients.edit (0 rows)');

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Meera', registered_branch_id = 'a1111111-0000-4000-8000-000000000002'
                        where id = 'aa000000-0000-4000-8000-000000000003'$$) = 1,
  'tenant admin can still move a patient between branches');

select tests.as_superuser();
select tests.ok(
  (select first_name = 'Meera' and registered_branch_id = 'a1111111-0000-4000-8000-000000000002'
   from patient.patients where id = 'aa000000-0000-4000-8000-000000000003'),
  'the permitted edits landed and the East registration was restored');

rollback;
