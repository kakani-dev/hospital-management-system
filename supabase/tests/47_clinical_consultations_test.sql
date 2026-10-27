-- Consultation + prescription v1 (20261026090000). Synthetic data only; the transaction rolls back.
begin;

create or replace function pg_temp.act(p_user uuid, p_role text default 'hms_svc_scheduling')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  execute format('set local role %I', p_role);
end;
$$;

select tests.ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'clinical' and c.relname in ('consultations', 'prescription_lines')),
  'RLS is enabled on every clinical table');
select tests.ok(
  (select count(*) = 10 from information_schema.columns
   where table_schema = 'clinical' and table_name in ('consultations', 'prescription_lines')
     and column_name in ('created_on', 'created_by', 'updated_on', 'updated_by', 'is_deleted')),
  'both clinical tables carry the audit fields');
select tests.ok(
  exists (select 1 from identity.role_permissions where role = 'doctor' and permission = 'clinical.write')
  and not exists (select 1 from identity.role_permissions where permission = 'clinical.write' and role <> 'doctor')
  and not exists (select 1 from identity.role_permissions where permission like 'clinical.%'
                  and role in ('receptionist', 'billing', 'accountant', 'pharmacist', 'lab_technician', 'viewer')),
  'only doctors write clinical data; reception, billing and the rest see none');
select tests.ok(
  not has_table_privilege('authenticated', 'clinical.consultations', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'clinical.consultations', 'update')
  and not has_table_privilege('hms_svc_billing', 'clinical.consultations', 'select'),
  'no direct writes; billing cannot read consultations');

-- Fixtures (Alpha East = consultant's branch; Alpha Main is outside the consultant's scope).
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values
  ('f4700000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-07-01', 4701, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'waiting'),
  ('f4700000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-07-01', 4702, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f4700000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
   '2035-07-01', 4703, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'waiting'),
  ('f4700000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-07-01', 4704, 'aa000000-0000-4000-8000-000000000003', 'c1111111-0000-4000-8000-000000000001', 'waiting');
update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000003';
-- #128: finalize needs a council registration number (20261027120000).
update appointment.practitioners set registration_number = 'NMC/4700001' where id = 'c1111111-0000-4000-8000-000000000001';

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  doc uuid := '0d000000-0000-4000-8000-000000000001';
  v jsonb;
  v2 jsonb;
  cid uuid;
  rv int;
  n int;
begin
  perform pg_temp.act(doc);
  v := clinical.start_consultation(t, 'f4700000-0000-4000-8000-000000000001', null);
  cid := (v ->> 'id')::uuid;
  perform tests.ok(v ->> 'status' = 'draft' and (v ->> 'version')::int = 1, 'a doctor opens a draft from a checked-in queue entry');
  v2 := clinical.start_consultation(t, 'f4700000-0000-4000-8000-000000000001', null);
  perform tests.ok(v2 ->> 'id' = cid::text and (select count(*) from clinical.consultations where queue_entry_id = 'f4700000-0000-4000-8000-000000000001') = 1,
    'double-submit of start returns the same draft (one row)');

  v := clinical.save_consultation(t, cid, 1, jsonb_build_object(
    'chiefComplaint', 'Fever 3 days', 'diagnosisText', 'Viral fever', 'diagnosisCode', 'r50.9', 'advice', 'Fluids',
    'followUpDate', '2035-07-08',
    'lines', jsonb_build_array(jsonb_build_object('medicineName', 'Paracetamol', 'strength', '500 mg', 'dose', '1 tab',
      'frequency', '1-0-1', 'durationDays', 5, 'route', 'oral', 'foodTiming', 'after_food'))));
  rv := (v ->> 'rowVersion')::int;
  perform tests.ok(rv = 2 and jsonb_array_length(v -> 'lines') = 1 and v ->> 'diagnosisCode' = 'R50.9',
    'saving a draft stores header and lines and bumps rowVersion');

  perform tests.throws_ok(format($q$select clinical.save_consultation(%L, %L, 1, '{}'::jsonb)$q$, t, cid), '40001',
    'a save with a stale rowVersion is a concurrency conflict');
  perform tests.throws_ok(format($q$select clinical.save_consultation(%L, %L, %s, '{"lines":[{"medicineName":"X","dose":"1","frequency":"1-0-0","durationDays":0}]}'::jsonb)$q$, t, cid, rv), '22023',
    'a line with duration 0 is rejected');
  perform tests.throws_ok(format($q$select clinical.save_consultation(%L, %L, %s, '{"lines":[{"medicineName":"X","dose":"0","frequency":"1-0-0","durationDays":3}]}'::jsonb)$q$, t, cid, rv), '22023',
    'a line with dose 0 is rejected');
  perform tests.throws_ok(format($q$select clinical.save_consultation(%L, %L, %s, '{"lines":[{"medicineName":" ","dose":"1","frequency":"1-0-0","durationDays":3}]}'::jsonb)$q$, t, cid, rv), '22023',
    'an empty line (no medicine) is rejected');
  perform tests.throws_ok(format($q$select clinical.consultation_print(%L, %L)$q$, t, cid), '55000',
    'printing a draft is blocked');

  v := clinical.finalize_consultation(t, cid, rv);
  perform tests.ok(v ->> 'status' = 'finalized' and v ->> 'finalizedOn' is not null, 'the doctor finalizes the draft');
  v2 := clinical.finalize_consultation(t, cid, rv);
  perform tests.ok(v2 ->> 'rowVersion' = v ->> 'rowVersion', 'a second finalize is a no-op');
  execute 'reset role';
  select count(*) into n from messaging.outbox where aggregate_id = cid and event_type = 'consultation.finalized';
  perform tests.ok(n = 1, 'finalize emits exactly one outbox event, even when double-submitted');
  perform tests.ok(not exists (select 1 from messaging.outbox o where o.aggregate_id = cid
                               and (o.payload ? 'notes' or o.payload ? 'diagnosisText' or o.payload ? 'chiefComplaint')),
    'the event carries identifiers only, no clinical text');
  perform tests.throws_ok(format($q$update clinical.consultations set notes = 'x' where id = %L$q$, cid), '55000',
    'even the owner cannot update a finalized row');
  perform tests.throws_ok(format($q$delete from clinical.prescription_lines where consultation_id = %L$q$, cid), '55000',
    'finalized lines cannot be deleted');

  perform pg_temp.act(doc);
  perform tests.throws_ok(format($q$select clinical.save_consultation(%L, %L, %s, '{}'::jsonb)$q$, t, cid, rv + 1), '55000',
    'editing after finalize is blocked');
  v := clinical.consultation_print(t, cid);
  perform tests.ok(v -> 'patient' ->> 'mrn' is not null and v -> 'doctor' ? 'registrationNumber' and v -> 'branch' ->> 'name' is not null,
    'the print view carries branch header, doctor registration and patient MRN');

  v := clinical.revise_consultation(t, cid);
  v2 := clinical.revise_consultation(t, cid);
  perform tests.ok((v ->> 'version')::int = 2 and v ->> 'status' = 'draft' and v ->> 'supersedesId' = cid::text
                   and jsonb_array_length(v -> 'lines') = 1 and v2 ->> 'id' = v ->> 'id',
    'a correction is a new draft version copied from the final one (idempotent)');
  perform tests.ok((clinical.start_consultation(t, 'f4700000-0000-4000-8000-000000000001', null) ->> 'version')::int = 2,
    'reopening the visit returns the latest version');
  perform tests.ok(jsonb_array_length(clinical.patient_consultations(t, 'aa000000-0000-4000-8000-000000000001')) = 2,
    'patient history lists both versions');

  perform tests.throws_ok(format($q$select clinical.start_consultation(%L, 'f4700000-0000-4000-8000-000000000002', null)$q$, t), '55000',
    'a patient who is not checked in (visit done) cannot get a new consultation');
  perform tests.throws_ok(format($q$select clinical.start_consultation(%L, 'f4700000-0000-4000-8000-000000000004', null)$q$, t), '55000',
    'a deleted patient cannot get a consultation');
  perform tests.throws_ok(format($q$select clinical.start_consultation(%L, 'f4700000-0000-4000-8000-000000000003', null)$q$, t), '42501',
    'a doctor cannot open a consultation at a branch outside their scope');

  -- Wrong role: tenant admin reads, but cannot write; reception sees nothing.
  perform pg_temp.act('0a000000-0000-4000-8000-000000000001');
  perform tests.ok(clinical.get_consultation(t, cid) ->> 'id' = cid::text, 'tenant admin can read a consultation');
  perform tests.throws_ok(format($q$select clinical.revise_consultation(%L, %L)$q$, t, cid), '42501',
    'tenant admin (no clinical.write) cannot correct a consultation');
  perform pg_temp.act('0a000000-0000-4000-8000-000000000002');
  perform tests.throws_ok(format($q$select clinical.get_consultation(%L, %L)$q$, t, cid), '42501',
    'reception cannot read clinical notes');
  perform tests.ok((select count(*) from clinical.consultations) = 0, 'RLS hides consultations from reception');

  -- Cross tenant: Beta's doctor cannot reach an Alpha consultation by either tenant id.
  perform pg_temp.act('0b000000-0000-4000-8000-000000000002');
  perform tests.throws_ok(format($q$select clinical.get_consultation(%L, %L)$q$, t, cid), 'P0002',
    'a Beta doctor cannot use the Alpha tenant id');
  perform tests.throws_ok(format($q$select clinical.get_consultation('22222222-2222-4222-8222-222222222222', %L)$q$, cid), 'P0002',
    'an Alpha consultation is not found under the Beta tenant');
  perform tests.throws_ok(format($q$select clinical.start_consultation('22222222-2222-4222-8222-222222222222', 'f4700000-0000-4000-8000-000000000001', null)$q$), 'P0002',
    'an Alpha queue entry is not found under the Beta tenant');
  execute 'reset role';
end;
$$;

rollback;
