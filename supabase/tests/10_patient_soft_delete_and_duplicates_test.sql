-- Sprint 2 §1: patient soft delete / restore and duplicate detection.
-- Migration 20261010090000_patient_soft_delete_and_duplicates.sql.
begin;

-- ---------- phone normalisation ----------
select tests.ok(patient.normalize_phone('+1-555-0101') = '15550101', 'normalize_phone keeps digits only');
select tests.ok(patient.normalize_phone('+91 98765 43210') = '9876543210', 'normalize_phone keeps the last 10 digits');
select tests.ok(patient.normalize_phone('12-345') is null and patient.normalize_phone(null) is null,
  'normalize_phone returns NULL below 7 digits');

-- ---------- duplicate detection (SECURITY INVOKER, RLS-scoped) ----------
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select array_agg(patient_id) from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', ' asha ', 'SYNTHETIC-ALPHA', '1985-04-12', null))
  = array['aa000000-0000-4000-8000-000000000001'::uuid],
  'name+DOB match is case/space-insensitive');
select tests.ok(
  (select match_reasons from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1985-04-12', '1 (555) 0101'))
  = array['name_dob', 'phone'],
  'name+DOB and phone together report both reasons');
select tests.ok(
  (select array_agg(patient_id) from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Someone', 'Else', '2000-01-01', '15550102'))
  = array['aa000000-0000-4000-8000-000000000002'::uuid],
  'phone-only match on normalised phone');
select tests.ok(
  not exists (select 1 from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1985-04-12', null,
     'aa000000-0000-4000-8000-000000000001')),
  'p_exclude_id excludes the patient being edited');
select tests.throws_ok(
  $$select * from patient.find_duplicate_patients(
     '22222222-2222-4222-8222-222222222222', 'John', 'Synthetic-Beta', '1965-09-21', '+1-555-0201')$$,
  'P0002', 'cross-tenant: Alpha reception searching Beta -> P0002 (404-not-403)');
select tests.throws_ok(
  $$select * from patient.find_duplicate_patients(gen_random_uuid(), 'A', 'B', '2000-01-01', null)$$,
  'P0002', 'unknown tenant -> P0002');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select * from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1985-04-12', '+1-555-0101')$$,
  'P0002', 'cross-tenant: Beta admin searching Alpha -> P0002');
select tests.ok(
  not exists (select 1 from patient.find_duplicate_patients(
     '22222222-2222-4222-8222-222222222222', 'Asha', 'Synthetic-Alpha', '1985-04-12', '+1-555-0101')),
  'Beta admin searching Beta with Alpha patient data gets 0 rows (no cross-tenant match)');
select tests.authenticate_as('outsider@example.test');
select tests.throws_ok(
  $$select * from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1985-04-12', null)$$,
  'P0002', 'user with no membership -> P0002');
select tests.authenticate_as('admin@beta.example');
select tests.ok(
  (select count(*) from patient.find_duplicate_patients(
     '22222222-2222-4222-8222-222222222222', 'Kiran', 'Synthetic-Beta', '1990-06-15', null)) = 1,
  'Beta admin finds the Beta duplicate only (same MRN/name exists in Alpha)');
select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  $$select * from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Asha', 'Synthetic-Alpha', '1985-04-12', null)$$,
  '42501', 'same-tenant lab technician (no registry read) -> 42501');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000001')$$,
  '42501', 'same-tenant lab technician deleting a patient -> 42501 (was P0002)');
select tests.throws_ok(
  $$select patient.soft_delete_patient('bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'lab technician deleting a Beta patient -> P0002');
select tests.authenticate_as('outsider@example.test');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000001')$$,
  'P0002', 'user with no membership deleting -> P0002');
select tests.throws_ok(
  $$select patient.restore_patient('aa000000-0000-4000-8000-000000000001')$$,
  'P0002', 'user with no membership restoring -> P0002');

-- ---------- privileges ----------
select tests.ok(
  not has_column_privilege('authenticated', 'patient.patients', 'deleted_at', 'UPDATE'),
  'authenticated cannot UPDATE patients.deleted_at directly');
select tests.ok(
  not has_function_privilege('anon', 'patient.soft_delete_patient(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'patient.restore_patient(uuid)', 'execute')
  and not has_function_privilege('anon', 'patient.find_duplicate_patients(uuid, text, text, date, text, uuid, text, text)', 'execute'),
  'anon cannot execute the patient RPCs');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '42501', 'reception cannot set deleted_at by direct UPDATE');

-- ---------- soft delete ----------
-- #273: the front desk cannot delete a patient record; only a hospital admin can.
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003', 'dup')$$,
  '42501', 'reception cannot delete a patient (hospital admin only) -> 42501');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002', repeat('x', 501))$$,
  '22023', 'deletion reason over 500 chars -> 22023');
savepoint meera_alive;
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003', 'dup');
select tests.ok(
  not exists (select 1 from patient.patients where id = 'aa000000-0000-4000-8000-000000000003' and deleted_at is null),
  'hospital admin can delete an East-registered patient');
rollback to savepoint meera_alive;
select tests.throws_ok(
  $$select patient.soft_delete_patient('bb000000-0000-4000-8000-000000000001', 'dup')$$,
  'P0002', 'cross-tenant: Alpha admin deleting a Beta patient -> P0002 (no existence leak)');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000001', 'dup')$$,
  '55000', 'patient with an open (booked) appointment cannot be deleted -> 55000');
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002', 'Duplicate of ALP-0001');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  not exists (select 1 from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'deleted patient disappears for reception');
select tests.ok(
  not exists (select 1 from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', 'Ravi', 'Synthetic-Alpha', '1972-11-03', '+1-555-0102')),
  'deleted patients are not reported as duplicates');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002')$$,
  'P0002', 'deleting again (already deleted) -> P0002');
select tests.throws_ok(
  $$select patient.restore_patient('aa000000-0000-4000-8000-000000000002')$$,
  '42501', 'same-tenant reception restoring a deleted patient -> 42501');

select tests.authenticate_as('consultant@shared.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'doctor cannot delete a patient -> 42501');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'cross-tenant: Beta admin deleting an Alpha patient -> P0002');

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select deleted_at is not null and deleted_by = '0a000000-0000-4000-8000-000000000001'
          and deletion_reason = 'Duplicate of ALP-0001'
   from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'tenant_admin still sees the deleted row with deleted_by (the admin who deleted it) and deletion_reason');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002')$$,
  'P0002', 'deleting an already-deleted patient -> P0002');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'X' where id = 'aa000000-0000-4000-8000-000000000002'$$) = 0,
  'deleted patients are read-only (UPDATE affects 0 rows, even for tenant_admin)');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0002', 'New', 'Person', '2000-01-01')$$,
  '42501', 'clients cannot supply an MRN at all (server-generated) -> 42501');
select tests.as_superuser();
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0002', 'New', 'Person', '2000-01-01')$$,
  '23505', 'the MRN of a deleted patient stays reserved, even for an explicit import -> 23505');
select tests.authenticate_as('admin@alpha.example');

-- ---------- restore ----------
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select patient.restore_patient('aa000000-0000-4000-8000-000000000001')$$,
  '42501', 'reception cannot restore -> 42501');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select patient.restore_patient('aa000000-0000-4000-8000-000000000002')$$,
  'P0002', 'cross-tenant: Beta admin restoring an Alpha patient -> P0002');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select patient.restore_patient('aa000000-0000-4000-8000-000000000001')$$,
  'P0002', 'restoring a patient that is not deleted -> P0002');
select patient.restore_patient('aa000000-0000-4000-8000-000000000002');
select tests.ok(
  (select deleted_at is null and deleted_by is null and deletion_reason is null
   from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'restore clears deleted_at/deleted_by/deletion_reason');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(exists (select 1 from patient.patients where id = 'aa000000-0000-4000-8000-000000000002'),
  'restored patient is visible to reception again');

-- ---------- consistency + audit ----------
select tests.as_superuser();
select tests.throws_ok(
  $$update patient.patients set deletion_reason = 'x' where id = 'aa000000-0000-4000-8000-000000000003'$$,
  '23514', 'deletion_reason without deleted_at violates patients_deleted_consistent');
select tests.ok(
  (select count(*) from audit.audit_log
   where table_name = 'patients' and record_id = 'aa000000-0000-4000-8000-000000000002' and action = 'UPDATE') >= 2,
  'soft delete and restore are written to the audit log');

rollback;
