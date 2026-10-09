-- Sprint 2 §2: practitioners, schedules, appointments (exclusion constraint, transitions, RLS).
-- Migration 20261010090100_appointment_schema.sql. Fixed future dates (2030-01-07 is a Monday).
begin;

-- ---------- structure ----------
select tests.ok(
  exists (select 1 from pg_constraint where conname = 'appointments_no_practitioner_overlap' and contype = 'x')
  and exists (select 1 from pg_constraint where conname = 'schedules_no_overlap' and contype = 'x'),
  'exclusion constraints exist on appointments and schedules');
select tests.ok(
  not has_table_privilege('authenticated', 'appointment.appointments', 'DELETE')
  and not has_column_privilege('authenticated', 'appointment.appointments', 'status', 'INSERT')
  and not has_column_privilege('authenticated', 'appointment.appointments', 'checked_in_at', 'UPDATE'),
  'no DELETE on appointments; status not insertable; lifecycle timestamps not client-updatable');

-- ---------- practitioners ----------
select tests.authenticate_as('lab@alpha.example');
select tests.ok((select count(*) from appointment.practitioners) = 2, 'any Alpha member sees the 2 Alpha practitioners only');
select tests.authenticate_as('admin@beta.example');
select tests.ok((select count(*) from appointment.practitioners) = 1, 'Beta admin sees only the Beta practitioner');
select tests.ok(
  tests.affected_rows($$update appointment.practitioners set display_name = 'Hacked' where id = 'c1111111-0000-4000-8000-000000000002'$$) = 0,
  'cross-tenant: Beta admin cannot update an Alpha practitioner (0 rows)');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$insert into appointment.practitioners (tenant_id, display_name) values ('11111111-1111-4111-8111-111111111111', 'Dr. New')$$,
  '42501', 'reception cannot create practitioners');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$insert into appointment.practitioners (tenant_id, display_name) values ('22222222-2222-4222-8222-222222222222', 'Dr. Planted')$$,
  '42501', 'cross-tenant: Alpha admin cannot create a practitioner in Beta');
insert into appointment.practitioners (id, tenant_id, display_name, is_active)
values ('c1111111-0000-4000-8000-0000000000ff', '11111111-1111-4111-8111-111111111111', 'Dr. Retired (synthetic)', false);
select tests.ok(exists (select 1 from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000ff'),
  'Alpha admin creates a practitioner');

-- ---------- schedules ----------
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000002', 1, '13:00', '15:00', '2026-01-01')$$,
  '23P01', 'overlapping weekly schedule for the same practitioner (even another branch) -> 23P01');
insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000002', 1, '14:00', '16:00', '2026-01-01');
select tests.ok(true, 'adjacent schedule (14:00 after 10:00-14:00) is accepted');
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'b2222222-0000-4000-8000-000000000001', 5, '09:00', '10:00', '2026-01-01')$$,
  'P0002', 'cross-tenant: schedule at a Beta branch -> P0002 (404-not-403)');
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c2222222-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 5, '09:00', '10:00', '2026-01-01')$$,
  'P0002', 'cross-tenant: schedule for a Beta practitioner -> P0002');
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('22222222-2222-4222-8222-222222222222', 'c2222222-0000-4000-8000-000000000001', 'b2222222-0000-4000-8000-000000000001', 5, '09:00', '10:00', '2026-01-01')$$,
  'P0002', 'cross-tenant: schedule inside Beta (all-Beta row) -> P0002');
select tests.throws_ok(
  $$update appointment.schedules set branch_id = 'b2222222-0000-4000-8000-000000000001' where id = 'd1111111-0000-4000-8000-000000000003'$$,
  'P0002', 'cross-tenant: moving a schedule to a Beta branch -> P0002');
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 5, '10:00', '09:00', '2026-01-01')$$,
  '23514', 'schedule with end before start -> 23514');
select tests.as_superuser();
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c2222222-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 5, '09:00', '10:00', '2026-01-01')$$,
  'P0002', 'reference trigger rejects another tenant''s practitioner even for superuser -> P0002');
alter table appointment.schedules disable trigger schedules_refs;
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c2222222-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 5, '09:00', '10:00', '2026-01-01')$$,
  '23503', 'backstop: with the trigger disabled the composite FK still rejects it -> 23503');
alter table appointment.schedules enable trigger schedules_refs;

-- ---------- booking ----------
select tests.authenticate_as('reception@alpha.example');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason)
values ('e1111111-0000-4000-8000-0000000000a1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002', '2030-01-08 10:00+05:30', '2030-01-08 10:30+05:30', 'Synthetic');
select tests.ok(
  (select status = 'booked' and created_on is not null and during = tstzrange(starts_at, ends_at, '[)')
   from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000a1'),
  'reception books an appointment: status booked, during generated');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000004', '2030-01-08 10:15+05:30', '2030-01-08 10:45+05:30')$$,
  '23P01', 'overlapping booking for the same practitioner -> 23P01');
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
        'aa000000-0000-4000-8000-000000000004', '2030-01-08 10:30+05:30', '2030-01-08 11:00+05:30');
select tests.ok(true, 'back-to-back booking ([) range) is accepted');
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001',
        'aa000000-0000-4000-8000-000000000004', '2030-01-08 10:00+05:30', '2030-01-08 10:30+05:30');
select tests.ok(true, 'same time with a different practitioner is accepted');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 09:00+05:30')$$,
  '23514', 'ends_at before starts_at -> 23514');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-0000000000ff',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  '23514', 'booking an inactive practitioner -> 23514 practitioner_inactive');

-- ---------- cross-tenant / deleted-patient negatives ----------
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'bb000000-0000-4000-8000-000000000001', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'cross-tenant: Alpha booking for a Beta patient -> P0002');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'cross-tenant: Alpha booking with a Beta practitioner -> P0002 (was 23503)');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'b2222222-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'cross-tenant: Alpha booking at a Beta branch -> P0002 (was 42501)');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
            'bb000000-0000-4000-8000-000000000001', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'cross-tenant: Alpha reception booking inside Beta (all-Beta row) -> P0002 (was 42501)');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  '42501', 'reception (Main only) cannot book at Alpha East -> 42501');
select tests.as_superuser();
select tests.as_owner('patient.patients');  -- the soft-delete state is owner-only (re-review R2)
update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000003';
select tests.as_superuser();
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000003', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'booking a soft-deleted patient -> P0002 (was 23503)');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', gen_random_uuid(),
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  'P0002', 'booking an unknown practitioner -> P0002');
select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  '42501', 'same-tenant lab technician booking -> 42501 (RLS)');
select tests.as_superuser();
alter table appointment.appointments disable trigger appointments_status_machine;
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30')$$,
  '23503', 'backstop: with the trigger disabled the composite FK rejects a Beta practitioner -> 23503');
alter table appointment.appointments enable trigger appointments_status_machine;
select tests.as_superuser();
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, status)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000004', '2030-01-09 10:00+05:30', '2030-01-09 10:30+05:30', 'completed')$$,
  '23514', 'inserting with a status other than booked -> 23514 (even as superuser)');

-- ---------- visibility ----------
select tests.authenticate_as('admin@beta.example');
select tests.ok(
  (select count(*) from appointment.appointments) = 1
  and not exists (select 1 from appointment.appointments where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'cross-tenant: Beta admin sees only the Beta appointment');
select tests.ok(
  tests.affected_rows($$update appointment.appointments set status = 'cancelled' where id = 'e1111111-0000-4000-8000-0000000000a1'$$) = 0,
  'cross-tenant: Beta admin cannot cancel an Alpha appointment (0 rows)');
select tests.authenticate_as('lab@alpha.example');
select tests.ok(not exists (select 1 from appointment.appointments), 'lab technician (no registry role) sees no appointments');
select tests.authenticate_as('consultant@shared.example');
select tests.ok(
  exists (select 1 from appointment.appointments where branch_id = 'a1111111-0000-4000-8000-000000000001')
  and exists (select 1 from appointment.appointments where tenant_id = '22222222-2222-4222-8222-222222222222'),
  'consultant reads appointments tenant-wide (contract §2.6, same as patients) in both tenants');
select tests.ok(
  tests.affected_rows($$update appointment.appointments set reason = 'x' where branch_id = 'a1111111-0000-4000-8000-000000000001'$$) = 0,
  'consultant (doctor @ Alpha East) cannot modify Alpha Main appointments (can_access_branch)');

-- ---------- transitions ----------
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$update appointment.appointments set status = 'checked_in' where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  '23514', 'booked -> checked_in by direct UPDATE is refused (check_in RPC only)');
select tests.throws_ok(
  $$update appointment.appointments set status = 'no_show' where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  '23514', 'no_show before the start time -> 23514');
select tests.throws_ok(
  $$update appointment.appointments set status = 'completed' where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  '23514', 'booked -> completed -> 23514');
select tests.throws_ok(
  $$update appointment.appointments set practitioner_id = 'c2222222-0000-4000-8000-000000000001' where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  'P0002', 'cross-tenant: re-assigning to a Beta practitioner -> P0002 (was 23503)');
update appointment.appointments set starts_at = '2030-01-08 12:00+05:30', ends_at = '2030-01-08 12:30+05:30'
where id = 'e1111111-0000-4000-8000-0000000000a1';
select tests.ok(
  (select during = tstzrange('2030-01-08 12:00+05:30', '2030-01-08 12:30+05:30', '[)') from appointment.appointments
   where id = 'e1111111-0000-4000-8000-0000000000a1'),
  'a booked appointment can be rescheduled (during recomputed)');
select tests.throws_ok(
  $$update appointment.appointments set checked_in_at = now() where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  '42501', 'lifecycle timestamps are not client-writable');
update appointment.appointments set status = 'cancelled', cancel_reason = 'Patient request'
where id = 'e1111111-0000-4000-8000-0000000000a1';
select tests.ok(
  (select status = 'cancelled' and cancelled_at is not null from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000a1'),
  'booked -> cancelled stamps cancelled_at');
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
        'aa000000-0000-4000-8000-000000000004', '2030-01-08 12:00+05:30', '2030-01-08 12:30+05:30');
select tests.ok(true, 'a cancelled appointment frees its time slot');
select tests.throws_ok(
  $$update appointment.appointments set status = 'booked' where id = 'e1111111-0000-4000-8000-0000000000a1'$$,
  '23514', 'cancelled is terminal -> 23514');

-- past appointment: no_show allowed, then terminal and frees the slot
select tests.as_superuser();
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('e1111111-0000-4000-8000-0000000000a2', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004', '2026-01-05 10:00+05:30', '2026-01-05 10:20+05:30');
select tests.authenticate_as('reception@alpha.example');
update appointment.appointments set status = 'no_show' where id = 'e1111111-0000-4000-8000-0000000000a2';
select tests.ok((select status = 'no_show' from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000a2'),
  'booked -> no_show after the start time');
select tests.as_superuser();
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
        'aa000000-0000-4000-8000-000000000001', '2026-01-05 10:00+05:30', '2026-01-05 10:20+05:30');
select tests.ok(true, 'a no_show appointment frees its time slot');

-- checked_in -> in_consultation needs a clinical role; reschedule after check-in refused
select set_config('appointment.check_in', 'e1111111-0000-4000-8000-000000000001', true);
update appointment.appointments set status = 'checked_in' where id = 'e1111111-0000-4000-8000-000000000001';
select set_config('appointment.check_in', '', true);
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$update appointment.appointments set status = 'in_consultation' where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '42501', 'receptionist cannot start a consultation -> 42501');
select tests.throws_ok(
  $$update appointment.appointments set starts_at = starts_at + interval '1 hour', ends_at = ends_at + interval '1 hour'
    where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '23514', 'rescheduling a checked-in appointment -> 23514');
select tests.authenticate_as('admin@alpha.example');
update appointment.appointments set status = 'in_consultation' where id = 'e1111111-0000-4000-8000-000000000001';
select tests.throws_ok(
  $$update appointment.appointments set status = 'cancelled' where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '23514', 'in_consultation -> cancelled by direct UPDATE is refused (queue sync only)');
update appointment.appointments set status = 'completed' where id = 'e1111111-0000-4000-8000-000000000001';
select tests.ok(
  (select status = 'completed' and checked_in_at is not null and started_at is not null and completed_at is not null
   from appointment.appointments where id = 'e1111111-0000-4000-8000-000000000001'),
  'checked_in -> in_consultation -> completed by tenant_admin stamps all lifecycle timestamps');
select tests.throws_ok(
  $$update appointment.appointments set status = 'cancelled' where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '23514', 'completed is terminal -> 23514');
select tests.throws_ok(
  $$delete from appointment.appointments where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '42501', 'appointments cannot be deleted');

-- ---------- available_slots ----------
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select count(*) from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                                     '2030-01-07', '2030-01-07')) = 11,
  'Monday at Alpha Main: 12 x 20-min slots (10:00-14:00) minus the seeded 10:00 booking = 11');
select tests.ok(
  (select min(slot_start) = '2030-01-07 10:20+05:30' and max(slot_end) = '2030-01-07 14:00+05:30'
   from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                    '2030-01-07', '2030-01-07')),
  'slots are generated in branch-local time (Asia/Kolkata)');
select tests.ok(
  (select count(*) from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                                     '2030-01-08', '2030-01-08', 'c1111111-0000-4000-8000-000000000002')) = 12 - 2 - 2,
  'Tuesday: slots overlapping the 10:30-11:00 and 12:00-12:30 bookings are removed (2 each); the cancelled booking frees its slots');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', '2030-01-01', '2030-03-01')$$,
  '22023', 'range over 31 days -> 22023');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', '2030-01-07', '2030-01-07')$$,
  '42501', 'reception (Main only) asking for Alpha East slots -> 42501');
select tests.throws_ok(
  $$select * from appointment.available_slots('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', '2030-01-07', '2030-01-07')$$,
  'P0002', 'cross-tenant: Alpha reception asking for Beta slots -> P0002 (was 42501)');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'b2222222-0000-4000-8000-000000000001', '2030-01-07', '2030-01-07')$$,
  'P0002', 'cross-tenant: Alpha tenant id with a Beta branch id -> P0002 (was 42501)');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', '2030-01-07', '2030-01-07',
      'c2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: Beta practitioner filter on Alpha slots -> P0002');
select tests.authenticate_as('outsider@example.test');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', '2030-01-07', '2030-01-07')$$,
  'P0002', 'user with no membership -> P0002');

-- ---------- practitioner deletion ----------
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$delete from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000ff'$$,
  '42501', 'hard DELETE of practitioners is no longer granted (soft delete only)');
select tests.throws_ok(
  $$select appointment.soft_delete_practitioner('c1111111-0000-4000-8000-000000000002')$$,
  '55000', 'soft-deleting a practitioner with open appointments -> 55000 (cancel them first)');
select appointment.soft_delete_practitioner('c1111111-0000-4000-8000-0000000000ff');
select tests.ok(
  (select is_deleted and not is_active from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000ff'),
  'tenant_admin soft-deletes a practitioner without appointments');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select appointment.soft_delete_schedule('d1111111-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: Beta admin cannot delete an Alpha schedule (not found)');

rollback;
