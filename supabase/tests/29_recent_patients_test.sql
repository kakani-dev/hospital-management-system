-- GET /patients?sort=recent: appointment.patient_last_booked_v1 (tenant + patients.view scoped).
begin;

select tests.authenticate_as('reception@alpha.example');
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-02-04 11:00+05:30', '2030-02-04 11:20+05:30');
select tests.ok(
  (select patient_id from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 5) limit 1)
    = 'aa000000-0000-4000-8000-000000000002',
  'recent: the patient booked just now comes first');
select tests.ok(
  (select count(*) from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 1)) = 1,
  'recent: the limit is applied');
select tests.ok(
  (select count(*) = count(distinct patient_id) from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 500)),
  'recent: one row per patient');
select tests.ok(
  (select bool_and(a >= b) from (
     select last_booked_at a, lead(last_booked_at) over (order by last_booked_at desc) b
     from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 500)) x where b is not null),
  'recent: newest booking first');

select tests.authenticate_as('lab@alpha.example');
select tests.ok(
  not exists (select 1 from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 5)),
  'recent: a lab technician (no patients.view) gets nothing');

select tests.authenticate_as('admin@beta.example');
select tests.ok(
  not exists (select 1 from appointment.patient_last_booked_v1('11111111-1111-4111-8111-111111111111', 5)),
  'recent: another tenant''s admin gets nothing for Alpha');

select tests.as_superuser();
select tests.ok(
  exists (select 1 from pg_indexes where indexname = 'appointments_tenant_created_idx')
  and exists (select 1 from pg_indexes where indexname = 'patients_tenant_created_idx'),
  'recent: the supporting indexes exist');
select tests.ok(
  not has_function_privilege('anon', 'appointment.patient_last_booked_v1(uuid, integer)', 'execute'),
  'recent: anon cannot execute the function');

rollback;
