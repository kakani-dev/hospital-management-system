-- Hospital-wide charts, hard duplicate identifiers, and a follow-up at another branch.
begin;

select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  tests.affected_rows($$update patient.patients set email = 'meera-desk@patients.example'
                        where id = 'aa000000-0000-4000-8000-000000000003'$$) = 1,
  'reception@Main can update an East patient');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000003', '+919800000301', true, null);
select tests.ok(
  (select phone_e164 from patient.patient_phones
    where patient_id = 'aa000000-0000-4000-8000-000000000003' and is_primary and not is_deleted) = '+919800000301',
  'reception@Main can set the phone of an East patient');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Nope'
                        where id = 'bb000000-0000-4000-8000-000000000001'$$) = 0,
  'reception@Main cannot update a Beta patient (0 rows)');

select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003', 'no')$$,
  '42501', 'lab technician cannot delete a patient');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003', 'no')$$,
  'P0002', 'Beta admin deleting an Alpha patient -> P0002');

select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select match_reasons from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', null, null)) = array['name'],
  'exact name with a blank date of birth warns as name');
select tests.ok(
  (select count(*) from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1999-01-01', null)) = 0,
  'a different date of birth is not a name match');
select tests.ok(
  (select match_reasons from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Someone', 'Else', null, null, null, 'ASHA@patients.example', null))
  = array['email'],
  'email matches regardless of case');

select tests.throws_ok(
  $$insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, email)
    values ('aa310000-0000-4000-8000-0000000000e1', '11111111-1111-4111-8111-111111111111',
            'a1111111-0000-4000-8000-000000000001', 'Copy', 'Mail', 'asha@patients.example')$$,
  '23505', 'a second live chart cannot reuse an email');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa310000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Copy', 'Phone');
select tests.throws_ok(
  $$select patient.set_patient_phones('aa310000-0000-4000-8000-000000000001', '+919800000101', true, null)$$,
  '23505', 'a second live chart cannot reuse a phone number');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, abha_number)
values ('aa310000-0000-4000-8000-0000000000a1', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Copy', 'Abha', '91-1111-2222-3333');
select tests.throws_ok(
  $$insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, abha_number)
    values ('aa310000-0000-4000-8000-0000000000a2', '11111111-1111-4111-8111-111111111111',
            'a1111111-0000-4000-8000-000000000001', 'Other', 'Abha', '91-1111-2222-3333')$$,
  '23505', 'a second live chart cannot reuse an ABHA number');

select tests.authenticate_as('admin@beta.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, email)
values ('bb310000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
        'b2222222-0000-4000-8000-000000000001', 'Reuse', 'Mail', 'asha@patients.example');
select tests.ok(
  exists (select 1 from patient.patients where id = 'bb310000-0000-4000-8000-000000000001'),
  'another hospital may reuse an email');

select tests.as_superuser();
insert into appointment.practitioners (id, tenant_id, display_name, specialty)
values ('c1310000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Dr. East Only (synthetic)', 'General Medicine');
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
values ('11111111-1111-4111-8111-111111111111', 'c1310000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002');
insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('d1310000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'c1310000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 3, '09:00', '13:00', 15, '2026-01-01');

select tests.authenticate_as('consultant@shared.example', '{"tenant_id":"11111111-1111-4111-8111-111111111111"}');
select tests.ok(
  not exists (select 1 from appointment.appointments where id = 'e1111111-0000-4000-8000-000000000001'),
  'a doctor at East cannot see a visit booked for another practitioner at Main');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
            'c1310000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001',
            '2032-03-03 09:00+05:30', '2032-03-03 09:15+05:30')$$,
  '42501', 'a doctor cannot book a fresh appointment');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
            'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001',
            '2032-03-01 10:00+05:30', '2032-03-01 10:15+05:30', 'e1111111-0000-4000-8000-000000000001')$$,
  '42501', 'a doctor cannot book at a branch they cannot access');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
            'c1310000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001',
            '2032-03-03 09:00+05:30', '2032-03-03 09:15+05:30', 'e1111111-0000-4000-8000-000000000001')$$,
  '42501', 'a doctor cannot follow up another clinician''s visit');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
            'c1310000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001',
            '2032-03-03 09:30+05:30', '2032-03-03 09:45+05:30', 'e2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'a parent visit from another hospital is unknown');

rollback;
