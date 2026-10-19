-- Level 1: normalized patient phones (20261019104000) and tenants.default_country_code (20261019103000).
begin;
select tests.as_superuser();

-- ------------------------------------------------------ country code ----
select tests.ok(
  (select bool_and(default_country_code = '+91') from identity.tenants where id in
    ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222')),
  'seed tenants (Asia/Kolkata) default to +91');
insert into identity.tenants (id, code, name, time_zone) values ('33333333-3333-4333-8333-333333333333', 'dubai-x', 'Dubai X (synthetic)', 'Asia/Dubai');
select tests.ok((select default_country_code from identity.tenants where id = '33333333-3333-4333-8333-333333333333') = '+971',
  'a new tenant gets its calling code from the time zone');
select tests.throws_ok($$update identity.tenants set default_country_code = '91' where id = '33333333-3333-4333-8333-333333333333'$$,
  '23514', 'default_country_code must look like +CCC');

-- ---------------------------------------------------------- to_e164 ----
select tests.ok(patient.to_e164('098765 43210', '+91') = '+919876543210', 'national number with trunk 0 -> +91');
select tests.ok(patient.to_e164('98765-43210', '+91') = '+919876543210', 'national number -> +91');
select tests.ok(patient.to_e164('919876543210', '+91') = '+919876543210', 'digits already carrying the calling code');
select tests.ok(patient.to_e164('+971 50 123 4567', '+91') = '+971501234567', 'international number kept');
select tests.ok(patient.to_e164('0044 20 7946 0000', '+91') = '+442079460000', '00 prefix -> +');
select tests.ok(patient.to_e164('12345', '+91') is null and patient.to_e164('call me', '+91') is null and patient.to_e164(null, '+91') is null,
  'too short / not a number / null -> NULL');

-- ------------------------------------------------------------ backfill ----
select tests.ok(
  (select phone from patient.patients where id = 'aa000000-0000-4000-8000-000000000001') = '+15550101'
  and (select count(*) from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted) = 2,
  'existing phones are copied as primary E.164 rows and the deprecated column mirrors them');
select tests.ok(
  (select count(*) = 1 and bool_and(is_primary and is_whatsapp) from patient.patient_phones
   where patient_id = 'aa000000-0000-4000-8000-000000000002' and not is_deleted),
  'WhatsApp same as phone = ONE row with both flags');

-- ------------------------------------------------------- constraints ----
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000001', '+919811111111', true)$$,
  '23505', 'at most one primary number per patient');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_whatsapp)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000001', '+919811111111', true)$$,
  '23505', 'at most one WhatsApp number per patient');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_whatsapp, is_primary)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003', '+919800000101', true, false),
           ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003', '+919800000101', false, true)$$,
  '23505', 'the same number is stored once per patient');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003', '9876543210', true)$$,
  '23514', 'phone_e164 must be E.164');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary)
    values ('22222222-2222-4222-8222-222222222222', 'aa000000-0000-4000-8000-000000000003', '+919876543210', true)$$,
  '23503', 'tenant consistency: a phone row cannot point at another tenant''s patient');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003', '+919876543210')$$,
  '23514', 'a row is a phone, a WhatsApp number, or both');

-- ------------------------------------------------- set_patient_phones ----
select tests.authenticate_as('reception@alpha.example');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919876543210', true, null);
select tests.ok(
  (select count(*) = 1 and bool_and(phone_e164 = '+919876543210' and is_primary and is_whatsapp)
   from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted)
  and (select phone from patient.patients where id = 'aa000000-0000-4000-8000-000000000001') = '+919876543210',
  'same as phone: one live row with both flags; old rows soft-deleted; mirror updated');
select tests.ok(
  (select count(*) from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and is_deleted) = 0,
  'RLS: soft-deleted numbers are hidden from non-admins');
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and is_deleted) = 2,
  'replaced numbers are soft-deleted, not removed (tenant_admin sees them)');
select tests.authenticate_as('reception@alpha.example');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919876543210', false, '+919000000001');
select tests.ok(
  (select array_agg(phone_e164 || ':' || is_primary || ':' || is_whatsapp order by phone_e164)
   from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted)
  = array['+919000000001:false:true', '+919876543210:true:false'],
  'a different WhatsApp number is a second row');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919000000001', false, '+919876543210');
select tests.ok(
  (select array_agg(phone_e164 || ':' || is_primary || ':' || is_whatsapp order by phone_e164)
   from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted)
  = array['+919000000001:true:false', '+919876543210:false:true'],
  'swapping phone and WhatsApp works (one primary / one WhatsApp keys hold)');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919000000001', false, '+919000000001');
select tests.ok(
  (select count(*) = 1 and bool_and(is_primary and is_whatsapp) from patient.patient_phones
   where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted),
  'a WhatsApp number equal to the phone collapses into the single row');
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919000000001', false, null);
select tests.ok(
  (select count(*) = 1 and bool_and(is_primary and not is_whatsapp) from patient.patient_phones
   where patient_id = 'aa000000-0000-4000-8000-000000000001' and not is_deleted),
  'no WhatsApp: the phone stays, the flag goes');
select tests.throws_ok($$select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '98765', false, null)$$,
  '22023', 'non-E.164 input -> 22023');
select tests.throws_ok($$select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', null, true, null)$$,
  '22023', 'WhatsApp same as phone without a phone -> 22023');
select tests.throws_ok($$select patient.set_patient_phones('aa000000-0000-4000-8000-000000000003', '+919876543210', true, null)$$,
  '42501', 'no writer role at the patient''s branch -> 42501');
select tests.throws_ok($$select patient.set_patient_phones('bb000000-0000-4000-8000-000000000001', '+919876543210', true, null)$$,
  'P0002', 'another tenant''s patient -> P0002');
select tests.throws_ok(
  $$insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary)
    values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000002', '+919811111111', false)$$,
  '42501', 'clients cannot write patient_phones directly');
select tests.throws_ok($$update patient.patients set phone = '+919811111111' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '42501', 'clients cannot write the deprecated patients.phone column');

-- duplicate check reads patient_phones (a WhatsApp-only number matches too)
select patient.set_patient_phones('aa000000-0000-4000-8000-000000000001', '+919000000001', false, '+919555500001');
select tests.ok(
  (select array_agg(patient_id) from patient.find_duplicate_patients('11111111-1111-4111-8111-111111111111', null, null, null, '095555 00001'))
  = array['aa000000-0000-4000-8000-000000000001'::uuid],
  'find_duplicate_patients matches any live number (here the WhatsApp one) of the patient');

-- --------------------------------------------------------------------- RLS ----
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from patient.patient_phones where tenant_id = '22222222-2222-4222-8222-222222222222') = 0
  and (select count(*) from patient.patient_phones) > 0,
  'RLS: Alpha sees only Alpha phone rows');
select tests.authenticate_as('outsider@example.test');
select tests.ok((select count(*) from patient.patient_phones) = 0, 'RLS: a non-member sees no phone rows');
select tests.ok(identity.tenant_default_country_code_v1('11111111-1111-4111-8111-111111111111') is null,
  'tenant_default_country_code_v1: NULL for a tenant the caller is not a member of');
select tests.authenticate_as('lab@alpha.example');
select tests.ok((select count(*) from patient.patient_phones) = 0, 'RLS: a member without a registry role sees no phone rows');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(identity.tenant_default_country_code_v1('11111111-1111-4111-8111-111111111111') = '+91',
  'tenant_default_country_code_v1: the member''s own tenant');
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002', 'synthetic phones');
select tests.ok(
  (select count(*) from patient.patient_phones where patient_id = 'aa000000-0000-4000-8000-000000000002') = 0,
  'RLS: phones of a soft-deleted patient are hidden from non-admins (mirrors patients)');

select tests.as_superuser();
select tests.ok(
  (select relrowsecurity from pg_class where oid = 'patient.patient_phones'::regclass)
  and not has_table_privilege('anon', 'patient.patient_phones', 'select')
  and not has_table_privilege('authenticated', 'patient.patient_phones', 'insert')
  and not has_table_privilege('authenticated', 'patient.patient_phones', 'update'),
  'patient_phones: RLS on, anon nothing, clients read-only');

rollback;
