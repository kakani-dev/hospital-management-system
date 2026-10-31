-- #275: the pharmacist sees age, sex and known allergies at dispense; allergies survive a chart merge.
-- Synthetic Zz-QA data; rolls back.
begin;

create or replace function pg_temp.act(p_user uuid, p_role text default 'hms_svc_inventory')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  execute format('set local role %I', p_role);
end;
$$;

select tests.ok(
  has_column_privilege('hms_svc_patients', 'patient.patients', 'known_allergies', 'update')
  and has_column_privilege('hms_svc_patients', 'patient.patients', 'known_allergies', 'insert')
  and not has_function_privilege('authenticated', 'pharmacy.patient_safety_json(uuid, uuid)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'pharmacy.patient_safety_json(uuid, uuid)', 'execute'),
  'patients service writes known_allergies; the pharmacy helper is internal');
select tests.throws_ok(
  $$update patient.patients set known_allergies = '' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'an empty allergy string is rejected (null means not recorded)');
select tests.ok(
  (select array_agg(permission order by permission) from identity.role_permissions where role = 'pharmacist')
    = array['branches.view', 'inventory.view', 'pharmacy.dispense', 'pharmacy.view', 'practitioners.view', 'settings.view'],
  'pharmacist permissions are unchanged (no patients.view)');

-- Fixtures: Zz-QA pharmacist at Alpha Main; a finalized prescription for Ravi (aa..02, born 1972-11-03).
insert into auth.users (id, email) values ('0e700000-0000-4000-8000-000000000001', 'zz-qa-pharmacist-70@synthetic.example');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e700000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 'pharmacist', 'active');
update appointment.practitioners set registration_number = 'NMC/7000001' where id = 'c1111111-0000-4000-8000-000000000001';
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values ('f7000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        (date '2035-08-01' + tests.fwd_days()), 7001, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done');
insert into clinical.consultations (id, tenant_id, branch_id, patient_id, practitioner_id, queue_entry_id, root_id, status, created_by, updated_by)
values ('c7000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'f7000000-0000-4000-8000-000000000001',
        'c7000000-0000-4000-8000-000000000001', 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001');
insert into clinical.prescription_lines (tenant_id, consultation_id, line_no, medicine_name, dose, frequency, duration_days, created_by, updated_by)
values ('11111111-1111-4111-8111-111111111111', 'c7000000-0000-4000-8000-000000000001', 1, 'Zz-QA Amoxicillin 500', '1 cap', '1-0-1', 5,
        '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001');
update clinical.consultations set status = 'finalized', finalized_by = '0d000000-0000-4000-8000-000000000001', finalized_on = now()
where id = 'c7000000-0000-4000-8000-000000000001';

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  ph uuid := '0e700000-0000-4000-8000-000000000001';
  rx uuid := 'c7000000-0000-4000-8000-000000000001';
  main uuid := 'a1111111-0000-4000-8000-000000000001';
  v jsonb;
  q jsonb;
  expected_age int := extract(year from age(inventory.branch_today(main)::timestamp, timestamp '1972-11-03'))::int;
begin
  -- Not recorded: explicit nulls, so the UI can warn.
  perform pg_temp.act(ph);
  q := (select e from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e where e ->> 'id' = rx::text);
  execute 'reset role';
  v := pharmacy.rx_json(t, rx, null);
  perform tests.ok(q is not null and q ? 'patientAllergies' and q -> 'patientAllergies' = 'null'::jsonb
    and v ? 'patientAllergies' and v -> 'patientAllergies' = 'null'::jsonb,
    'allergies not recorded: queue row and prescription carry patientAllergies = null');
  perform tests.ok((q ->> 'patientAgeYears')::int = expected_age and (v ->> 'patientAgeYears')::int = expected_age
    and q ->> 'patientSex' = 'male' and v ->> 'patientDateOfBirth' = '1972-11-03'
    and (v ->> 'patientDobEstimated')::boolean = false,
    'queue and prescription carry age (branch-local), sex, DOB and the estimated flag');

  update patient.patients set known_allergies = '  Penicillin (rash); sulfa  ' where id = 'aa000000-0000-4000-8000-000000000002';
  perform pg_temp.act(ph);
  q := (select e from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e where e ->> 'id' = rx::text);
  execute 'reset role';
  v := pharmacy.rx_json(t, rx, null);
  perform tests.ok(q ->> 'patientAllergies' = 'Penicillin (rash); sulfa' and v ->> 'patientAllergies' = 'Penicillin (rash); sulfa',
    'recorded allergies reach the pharmacist (trimmed)');
  perform tests.ok(v ->> 'patientName' is not null and v ->> 'patientMrn' = 'ALP-0002' and jsonb_array_length(v -> 'lines') = 1,
    'existing prescription fields are unchanged');

  update patient.patients set date_of_birth = null, dob_estimated = false where id = 'aa000000-0000-4000-8000-000000000002';
  v := pharmacy.rx_json(t, rx, null);
  perform tests.ok(v ? 'patientAgeYears' and v -> 'patientAgeYears' = 'null'::jsonb, 'no DOB: age is null, not an error');
  perform tests.ok(pharmacy.patient_safety_json(gen_random_uuid(), main) -> 'patientAllergies' = 'null'::jsonb,
    'unknown patient: the helper returns explicit nulls');
end
$$;

-- Merge: the duplicate's allergies are kept on the survivor (Ravi, aa..02, cleared first).
create or replace function pg_temp.merge(p_dup uuid, p_into uuid) returns void language sql as $$
  update patient.patients set merged_into_patient_id = p_into, merged_at = now(), deleted_at = now(),
         merged_by = '0a000000-0000-4000-8000-000000000001'
  where id = p_dup
$$;
update patient.patients set known_allergies = null where id = 'aa000000-0000-4000-8000-000000000002';
update patient.patients set known_allergies = 'Sulfa' where id = 'aa000000-0000-4000-8000-000000000003';
update patient.patients set known_allergies = 'Ibuprofen' where id = 'aa000000-0000-4000-8000-000000000004';
update patient.patients set known_allergies = 'IBUPROFEN' where id = 'aa000000-0000-4000-8000-000000000001';
select pg_temp.merge('aa000000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000002');
select tests.ok((select known_allergies from patient.patients where id = 'aa000000-0000-4000-8000-000000000002') = 'Sulfa',
  'survivor with none recorded takes the duplicate''s list');
select pg_temp.merge('aa000000-0000-4000-8000-000000000004', 'aa000000-0000-4000-8000-000000000002');
select tests.ok((select known_allergies from patient.patients where id = 'aa000000-0000-4000-8000-000000000002') = 'Sulfa; Ibuprofen',
  'merge appends the duplicate''s allergies to the survivor''s');
select pg_temp.merge('aa000000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000002');
select tests.ok((select known_allergies from patient.patients where id = 'aa000000-0000-4000-8000-000000000002') = 'Sulfa; Ibuprofen',
  'the same allergy text is not appended twice (case-insensitive)');

rollback;
