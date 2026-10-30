-- #190: registration fields (20261030130000_patients_registration_fields). Synthetic data; rolls back.
begin;

select tests.ok(
  exists (select 1 from information_schema.columns where table_schema = 'patient' and table_name = 'patients' and column_name = 'dob_estimated')
  and exists (select 1 from information_schema.columns where table_schema = 'patient' and table_name = 'patients' and column_name = 'no_phone_reason')
  and has_column_privilege('hms_svc_patients', 'patient.patients', 'dob_estimated', 'insert')
  and has_column_privilege('hms_svc_patients', 'patient.patients', 'no_phone_reason', 'update'),
  'dob_estimated and no_phone_reason exist and the patients service can write them');

-- Single-name patient: blank last name is allowed, blank first name is not.
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, sex, date_of_birth, dob_estimated, no_phone_reason)
values ('aa190000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'Zzqasinglename', '', 'female', '1966-10-30', true, 'Elderly, no phone');
select tests.ok(
  (select last_name = '' and dob_estimated and no_phone_reason = 'Elderly, no phone' from patient.patients where id = 'aa190000-0000-4000-8000-000000000001'),
  'a single-name patient with an estimated DOB and a no-phone reason is stored');

select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', ' ', 'X')$$,
  '23514', 'first name is still required');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, first_name, last_name, dob_estimated)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Zzqa', '', true)$$,
  '23514', 'an estimated DOB needs a DOB');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, first_name, last_name, no_phone_reason)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Zzqa', '', 'x')$$,
  '23514', 'a no-phone reason is 3 to 200 characters');

-- Duplicate detection: two single-name patients with the same first name match on name.
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select match_reasons from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'zzqasinglename', '', null, null)) = array['name'],
  'a blank last name matches another single-name patient by first name');
select tests.ok(
  (select match_reasons from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'zzqasinglename', null, '1966-10-30', null)) = array['name_dob'],
  'a null last name is treated as blank, and name+DOB still matches');
select tests.ok(
  not exists (select 1 from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'zzqasinglename', 'Kumar', null, null)),
  'a two-part name does not match a single-name patient');

rollback;
