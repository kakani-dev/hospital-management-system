-- #58: registration details (address, PIN, emergency contact, guardian, blood group, referral) and
-- the per-tenant registration settings. Synthetic Zz-QA data; rolls back.
begin;

select tests.ok(
  has_column_privilege('hms_svc_patients', 'patient.patients', 'pin_code', 'insert')
  and has_column_privilege('hms_svc_patients', 'patient.patients', 'emergency_contact_phone', 'update')
  and has_column_privilege('hms_svc_patients', 'patient.patients', 'blood_group', 'select')
  and has_table_privilege('hms_svc_patients', 'patient.registration_settings', 'update')
  and not has_table_privilege('authenticated', 'patient.registration_settings', 'select')
  and not has_table_privilege('hms_svc_patients', 'patient.registration_settings', 'delete'),
  'patients service owns the registration columns and settings; clients cannot read settings directly');

-- Ravi (aa..02) is an existing synthetic patient.
select tests.throws_ok($$update patient.patients set pin_code = '012345' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'a PIN code cannot start with 0');
select tests.throws_ok($$update patient.patients set pin_code = '56001' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'a PIN code must have 6 digits');
select tests.throws_ok($$update patient.patients set blood_group = 'A positive' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'blood group must be one of the 8 ABO/Rh groups (null = not recorded)');
select tests.throws_ok($$update patient.patients set emergency_contact_name = 'Zz-QA Kin' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'an emergency contact needs both a name and a phone');
select tests.throws_ok($$update patient.patients set emergency_contact_name = 'Zz-QA Kin', emergency_contact_phone = '98450 00000' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'the emergency phone is stored normalized (E.164)');
select tests.throws_ok($$update patient.patients set referral_source = 'friend' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23514', 'referral source is a known value');
update patient.patients set pin_code = '560001', state = 'Karnataka', blood_group = 'O+',
  emergency_contact_name = 'Zz-QA Kin', emergency_contact_relation = 'Wife', emergency_contact_phone = '+919845000000',
  referral_source = 'doctor', referred_by = 'Zz-QA Dr Rao'
 where id = 'aa000000-0000-4000-8000-000000000002';
select tests.ok((select pin_code = '560001' and blood_group = 'O+' from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'valid registration details are stored');

select tests.throws_ok($$insert into patient.registration_settings (tenant_id, guardian_required_below_age_years, created_by, updated_by)
  values ('11111111-1111-4111-8111-111111111111', 30, '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001')$$,
  '23514', 'guardian age limit is 0 to 21');

rollback;
