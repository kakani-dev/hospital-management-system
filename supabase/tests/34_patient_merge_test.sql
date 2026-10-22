-- Merge a duplicate chart into the one we keep: visits, queue, phones, audit, outbox.
-- The batch job keeps the oldest chart. Merged charts cannot be restored.
begin;

select tests.ok(
  has_function_privilege('authenticated', 'patient.merge_patients(uuid, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'patient.merge_patients(uuid, uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'patient.merge_patients_apply(uuid, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'patient.merge_patients_apply(uuid, uuid, text)', 'execute')
  and not has_function_privilege('public', 'patient.merge_patients_apply(uuid, uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'patient.merge_duplicate_charts()', 'execute')
  and not has_function_privilege('authenticated', 'appointment.reassign_patient_for_merge(uuid, uuid, uuid)', 'execute'),
  'only patient.merge_patients is callable by a signed-in user');
select tests.ok(
  pg_get_indexdef('patient.patients_tenant_email_key'::regclass) like '%NOT is_deleted%'
  and pg_get_indexdef('patient.patients_tenant_email_key'::regclass) like '%merged_into_patient_id IS NULL%'
  and pg_get_indexdef('patient.patients_tenant_abha_key'::regclass) like '%merged_into_patient_id IS NULL%'
  and pg_get_indexdef('patient.patient_phones_tenant_number_key'::regclass) like '%NOT is_deleted%',
  'live email, phone and ABHA indexes skip merged charts');
select tests.ok(
  pg_get_functiondef('patient.merge_duplicate_charts()'::regprocedure) like '%patient.merge: % into %'
  and pg_get_functiondef('patient.merge_duplicate_charts()'::regprocedure) like '%patient.merge: no duplicate charts%',
  'the batch merge reports each chart it folds in');

select tests.authenticate_as('admin@alpha.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, sex, date_of_birth, email)
values ('aa340000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Keep', 'Chart', 'female', '1980-01-01', 'keep-340@synthetic.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, sex, date_of_birth, email, abha_number)
values ('aa340000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Copy', 'Chart', 'male', '1992-03-04',
        'copy-340@synthetic.example', '91-3400-1111-2222');
select patient.set_patient_phones('aa340000-0000-4000-8000-000000000002', '+919834000002', true, null);

select tests.throws_ok(
  $$select patient.merge_patients('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000001', 'same')$$,
  '22023', 'a chart cannot be merged into itself');
select tests.throws_ok(
  $$select patient.merge_patients('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', '   ')$$,
  '22023', 'a merge reason is required');
select tests.throws_ok(
  $$select patient.merge_patients('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', repeat('x', 501))$$,
  '22023', 'a merge reason is at most 500 characters');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select patient.merge_patients('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', 'desk')$$,
  '42501', 'a receptionist cannot merge charts');
select tests.throws_ok(
  $$select patient.merge_patients_apply('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', 'desk')$$,
  '42501', 'the apply function is not granted to clients');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select patient.merge_patients('aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', 'other hospital')$$,
  'P0002', 'a Beta admin merging Alpha charts is not found');
select tests.as_superuser();
select tests.ok(
  (select deleted_at is null and merged_into_patient_id is null from patient.patients where id = 'aa340000-0000-4000-8000-000000000002'),
  'a refused merge leaves the duplicate live');

select tests.as_superuser();
insert into appointment.practitioners (id, tenant_id, display_name, specialty)
values ('c1340000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Dr. Merge (synthetic)', 'General Medicine');
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
values ('11111111-1111-4111-8111-111111111111', 'c1340000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('e1340000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'c1340000-0000-4000-8000-000000000001',
        'aa340000-0000-4000-8000-000000000002', '2035-06-02 10:00+05:30', '2035-06-02 10:15+05:30');
update appointment.appointments set status = 'cancelled' where id = 'e1340000-0000-4000-8000-000000000001';
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('e1340000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'c1340000-0000-4000-8000-000000000001',
        'aa340000-0000-4000-8000-000000000002', '2035-06-02 11:00+05:30', '2035-06-02 11:15+05:30');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
values ('e1340000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'c1340000-0000-4000-8000-000000000001',
        'aa340000-0000-4000-8000-000000000002', '2035-06-02 11:30+05:30', '2035-06-02 11:45+05:30',
        'e1340000-0000-4000-8000-000000000002');
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, status)
values ('f1340000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', '2035-06-02', 3401, 'aa340000-0000-4000-8000-000000000001', 'waiting'),
       ('f1340000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', '2035-06-02', 3402, 'aa340000-0000-4000-8000-000000000002', 'waiting'),
       ('f1340000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', '2034-12-01', 3403, 'aa340000-0000-4000-8000-000000000002', 'done');

select tests.authenticate_as('admin@alpha.example');
select patient.merge_patients(
  'aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', 'Same person, second chart');

select tests.as_superuser();
select tests.ok(
  (select email = 'keep-340@synthetic.example' and sex = 'female' and date_of_birth = '1980-01-01'
          and abha_number = '91-3400-1111-2222' and phone = '+919834000002'
     from patient.patients where id = 'aa340000-0000-4000-8000-000000000001'),
  'blank survivor fields are filled and non-blank fields stay');
select tests.ok(
  (select deleted_at is not null and is_deleted and merged_into_patient_id = 'aa340000-0000-4000-8000-000000000001'
          and merged_at is not null and merged_by = '0a000000-0000-4000-8000-000000000001'
          and deletion_reason = 'Same person, second chart'
     from patient.patients where id = 'aa340000-0000-4000-8000-000000000002'),
  'the duplicate is soft-deleted and points at the survivor');
select tests.ok(
  (select count(*) = 3 and count(*) filter (where patient_id = 'aa340000-0000-4000-8000-000000000001') = 3
          and bool_and(parent_appointment_id is not distinct from
            case id when 'e1340000-0000-4000-8000-000000000003' then 'e1340000-0000-4000-8000-000000000002'::uuid end)
     from appointment.appointments where id in (
       'e1340000-0000-4000-8000-000000000001', 'e1340000-0000-4000-8000-000000000002', 'e1340000-0000-4000-8000-000000000003')),
  'appointments, including a cancelled visit and a follow-up, point at the survivor and keep their parent');
select tests.ok(
  (select status = 'cancelled' from appointment.appointments where id = 'e1340000-0000-4000-8000-000000000001'),
  'a cancelled visit stays cancelled when its patient changes');
select tests.ok(
  (select status = 'waiting' and patient_id = 'aa340000-0000-4000-8000-000000000001'
     from appointment.queue_entries where id = 'f1340000-0000-4000-8000-000000000001')
  and (select status = 'cancelled' and patient_id = 'aa340000-0000-4000-8000-000000000001' and cancelled_at is not null
     from appointment.queue_entries where id = 'f1340000-0000-4000-8000-000000000002')
  and (select status = 'done' and patient_id = 'aa340000-0000-4000-8000-000000000001'
     from appointment.queue_entries where id = 'f1340000-0000-4000-8000-000000000003'),
  'a colliding active queue entry is cancelled; every queue row moves to the survivor');
select tests.ok(
  (select patient_id = 'aa340000-0000-4000-8000-000000000001' and is_primary and is_whatsapp and not is_deleted
     from patient.patient_phones where phone_e164 = '+919834000002' and not is_deleted),
  'the duplicate phone moves onto the survivor');
select tests.ok(
  exists (select 1 from audit.audit_log
           where schema_name = 'patient' and table_name = 'patients' and action = 'UPDATE'
             and record_id = 'aa340000-0000-4000-8000-000000000002'
             and new_data->>'merged_into_patient_id' = 'aa340000-0000-4000-8000-000000000001'),
  'the patient update is in the audit log');
select tests.ok(
  (select count(*) = 1
     and bool_and(payload = jsonb_build_object(
           'survivor_patient_id', 'aa340000-0000-4000-8000-000000000001',
           'duplicate_patient_id', 'aa340000-0000-4000-8000-000000000002',
           'tenant_id', '11111111-1111-4111-8111-111111111111')
         and payload::text not like '%@%'
         and payload::text not like '%Same person%')
     from messaging.outbox
    where aggregate_type = 'patient' and event_type = 'patient.merged'
      and aggregate_id = 'aa340000-0000-4000-8000-000000000001'),
  'one patient.merged outbox event carries ids only');

select tests.authenticate_as('admin@alpha.example');
select patient.merge_patients(
  'aa340000-0000-4000-8000-000000000001', 'aa340000-0000-4000-8000-000000000002', 'Same person, second chart');
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox
    where aggregate_type = 'patient' and event_type = 'patient.merged'
      and aggregate_id = 'aa340000-0000-4000-8000-000000000001'),
  'merging the same pair again does not write a second event');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select patient.restore_patient('aa340000-0000-4000-8000-000000000002')$$,
  '55000', 'a merged chart cannot be restored');
select tests.ok(
  (select count(*) = 0 from patient.find_duplicate_patients(
     '11111111-1111-4111-8111-111111111111', null, null, null, null, null, 'copy-340@synthetic.example', null)),
  'a merged chart is not a live duplicate');

-- The batch job: drop the live indexes inside this transaction, insert real duplicates, fold them.
select tests.as_superuser();
drop index patient.patients_tenant_email_key;
drop index patient.patient_phones_tenant_number_key;
drop index patient.patients_tenant_abha_key;
alter table patient.patients disable trigger patients_audit_columns;
insert into patient.patients (
  id, tenant_id, registered_branch_id, mrn, first_name, last_name, email,
  created_on, created_by, updated_on, updated_by, created_at, updated_at)
values
  ('aa340100-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'ZZZ-000003', 'Old', 'Mail', 'merge-batch@synthetic.example',
   '2020-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2020-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2020-01-01 00:00+00', '2020-01-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'AAA-000001', 'Mid', 'Mail', 'merge-batch@synthetic.example',
   '2021-06-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2021-06-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2021-06-01 00:00+00', '2021-06-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'MMM-000002', 'New', 'Mail', 'MERGE-BATCH@synthetic.example',
   '2022-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2022-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2022-01-01 00:00+00', '2022-01-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000011', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'ZZZ-000011', 'Old', 'Phone', null,
   '2019-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2019-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2019-01-01 00:00+00', '2019-01-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000010', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'AAA-000010', 'New', 'Phone', null,
   '2024-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2024-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2024-01-01 00:00+00', '2024-01-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000022', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'ZZZ-000022', 'Old', 'Abha', null,
   '2018-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2018-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2018-01-01 00:00+00', '2018-01-01 00:00+00'),
  ('aa340100-0000-4000-8000-000000000020', '11111111-1111-4111-8111-111111111111',
   'a1111111-0000-4000-8000-000000000001', 'AAA-000020', 'New', 'Abha', null,
   '2023-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2023-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2023-01-01 00:00+00', '2023-01-01 00:00+00'),
  ('bb340100-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
   'b2222222-0000-4000-8000-000000000001', 'BBB-000001', 'Other', 'Hospital', 'merge-batch@synthetic.example',
   '2010-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e', '2010-01-01 00:00+00', '00000000-0000-4000-8000-00000000005e',
   '2010-01-01 00:00+00', '2010-01-01 00:00+00');
alter table patient.patients enable trigger patients_audit_columns;
update patient.patients set abha_number = '91-3400-0000-0001'
 where id in ('aa340100-0000-4000-8000-000000000022', 'aa340100-0000-4000-8000-000000000020');
alter table patient.patient_phones disable trigger patient_phones_shared_number;
insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
values ('11111111-1111-4111-8111-111111111111', 'aa340100-0000-4000-8000-000000000011', '+919811110340', true, true),
       ('11111111-1111-4111-8111-111111111111', 'aa340100-0000-4000-8000-000000000010', '+919811110340', true, true);
alter table patient.patient_phones enable trigger patient_phones_shared_number;

select tests.ok(patient.merge_duplicate_charts() = 4, 'the batch merges four duplicate charts');
select tests.ok(
  (select deleted_at is null and merged_into_patient_id is null and mrn = 'ZZZ-000003'
     from patient.patients where id = 'aa340100-0000-4000-8000-000000000003')
  and (select merged_into_patient_id = 'aa340100-0000-4000-8000-000000000003' and deleted_at is not null
     from patient.patients where id = 'aa340100-0000-4000-8000-000000000001')
  and (select merged_into_patient_id = 'aa340100-0000-4000-8000-000000000003'
     from patient.patients where id = 'aa340100-0000-4000-8000-000000000002'),
  'the oldest email chart survives, not the smallest id or the first MRN');
select tests.ok(
  (select merged_into_patient_id = 'aa340100-0000-4000-8000-000000000011'
     from patient.patients where id = 'aa340100-0000-4000-8000-000000000010')
  and (select merged_into_patient_id = 'aa340100-0000-4000-8000-000000000022'
     from patient.patients where id = 'aa340100-0000-4000-8000-000000000020'),
  'phone and ABHA duplicates fold into their oldest chart');
select tests.ok(
  (select deleted_at is null and merged_into_patient_id is null
     from patient.patients where id = 'bb340100-0000-4000-8000-000000000001'),
  'the same email in another hospital is not merged');
select tests.ok(patient.merge_duplicate_charts() = 0, 'a second batch run merges nothing');

rollback;
