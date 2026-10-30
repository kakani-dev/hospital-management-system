-- Vitals per visit (#104, 20261027140000). Synthetic Zz-QA data only; the transaction rolls back.
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

select tests.ok((select c.relrowsecurity from pg_class c where c.oid = 'clinical.vitals'::regclass), 'RLS is on for clinical.vitals');
select tests.ok(
  not has_table_privilege('authenticated', 'clinical.vitals', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'clinical.vitals', 'insert')
  and not has_table_privilege('hms_svc_scheduling', 'clinical.vitals', 'update')
  and not has_table_privilege('hms_svc_billing', 'clinical.vitals', 'select')
  and not has_function_privilege('authenticated', 'clinical.record_vitals(uuid, uuid, jsonb)', 'execute'),
  'no direct writes; authenticated and billing get nothing');
select tests.ok(
  (select array_agg(role::text order by role) from identity.role_permissions where permission = 'clinical.vitals')
    = array['doctor', 'nurse', 'tenant_admin'],
  'nurse, doctor (and tenant_admin) may record vitals; reception and billing may not');

-- Fixtures: a Zz-QA nurse at Alpha East; visits at Alpha East and Alpha Main.
insert into auth.users (id, email, aud, role) values
  ('0e540000-0000-4000-8000-000000000001', 'zz-qa-nurse@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e540000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 'nurse', 'active');
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values
  ('f5400000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5401, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'waiting'),
  ('f5400000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
   '2035-08-01', 5402, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'waiting'),
  ('f5400000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5403, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'cancelled'),
  ('f5400000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5404, 'aa000000-0000-4000-8000-000000000003', 'c1111111-0000-4000-8000-000000000001', 'waiting'),
  ('f5400000-0000-4000-8000-000000000005', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001',
   '2035-08-01', 5405, 'bb000000-0000-4000-8000-000000000001', null, 'waiting');
select tests.as_owner('patient.patients');  -- soft-delete state is owner-only; superuser is not enough on the Supabase stack (#237)
update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000003';
select tests.as_superuser();

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  beta uuid := '22222222-2222-4222-8222-222222222222';
  nurse uuid := '0e540000-0000-4000-8000-000000000001';
  doc uuid := '0d000000-0000-4000-8000-000000000001';
  q1 uuid := 'f5400000-0000-4000-8000-000000000001';
  v jsonb;
  v2 jsonb;
  bad text;
begin
  perform pg_temp.act(nurse);
  v := clinical.record_vitals(t, q1, jsonb_build_object('systolic', 120, 'diastolic', 80, 'pulse', 72, 'temperatureC', 36.8,
        'weightKg', 60, 'heightCm', 160, 'spo2', 98, 'respRate', 16, 'clientId', 'e5400000-0000-4000-8000-000000000001'));
  perform tests.ok(v ->> 'systolic' = '120' and (v -> 'flags') = '[]'::jsonb and v ->> 'bmi' = '23.4'
                   and v ->> 'patientId' = 'aa000000-0000-4000-8000-000000000001',
    'a nurse records normal vitals for a queued visit; no flags; BMI derived');
  v2 := clinical.record_vitals(t, q1, jsonb_build_object('pulse', 99, 'clientId', 'e5400000-0000-4000-8000-000000000001'));
  perform tests.ok(v2 ->> 'id' = v ->> 'id' and (select count(*) from clinical.vitals where queue_entry_id = q1) = 1,
    'double-submit with the same clientId returns the first reading (one row)');

  -- Hard limits: each is a 22023 with a field-specific message.
  foreach bad in array array[
    '{}', '{"note":"only a note"}', '{"systolic":120}', '{"diastolic":80}', '{"systolic":49,"diastolic":30}',
    '{"systolic":301,"diastolic":80}', '{"systolic":120,"diastolic":19}', '{"systolic":120,"diastolic":120}',
    '{"systolic":120.5,"diastolic":80}', '{"pulse":19}', '{"pulse":251}', '{"temperatureC":29.9}', '{"temperatureC":45.1}',
    '{"weightKg":0.2}', '{"weightKg":401}', '{"heightCm":19}', '{"heightCm":251}', '{"spo2":-1}', '{"spo2":101}',
    '{"spo2":97.5}', '{"respRate":3}', '{"respRate":81}', '{"pulse":"abc"}', '{"clientId":"nope","pulse":70}']
  loop
    perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, q1, bad), '22023', 'rejects ' || bad);
  end loop;
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, q1,
    jsonb_build_object('pulse', 70, 'note', repeat('x', 501))), '22023', 'rejects a note over 500 characters');

  -- Edges that are allowed.
  v := clinical.record_vitals(t, q1, '{"spo2":0}');
  perform tests.ok(v -> 'flags' @> '[{"field":"spo2","level":"critical"}]', 'SpO2 0 is accepted and flagged critical');
  v := clinical.record_vitals(t, q1, '{"spo2":100,"pulse":"","temperatureC":" "}');
  perform tests.ok(v ->> 'spo2' = '100' and v -> 'pulse' = 'null'::jsonb, 'SpO2 100 is accepted; blank fields are treated as not taken');

  -- Out-of-range (but possible) values are stored and flagged.
  v := clinical.record_vitals(t, q1, '{"systolic":150,"diastolic":95,"pulse":110,"temperatureC":38.4,"spo2":93,"respRate":24}');
  perform tests.ok(jsonb_array_length(v -> 'flags') = 6
                   and v -> 'flags' @> '[{"field":"systolic","level":"high"},{"field":"diastolic","level":"high"},{"field":"pulse","level":"high"},{"field":"temperature","level":"high"},{"field":"spo2","level":"low"},{"field":"respRate","level":"high"}]',
    'high BP, tachycardia, fever, low SpO2 and tachypnoea are each flagged');
  v := clinical.record_vitals(t, q1, '{"systolic":85,"diastolic":55,"pulse":50,"temperatureC":34.5,"respRate":10}');
  perform tests.ok(v -> 'flags' @> '[{"field":"systolic","level":"low"},{"field":"diastolic","level":"low"},{"field":"pulse","level":"low"},{"field":"temperature","level":"low"},{"field":"respRate","level":"low"}]',
    'low values are flagged low');

  -- Visit state.
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, 'f5400000-0000-4000-8000-000000000003', '{"pulse":70}'),
    '55000', 'a cancelled visit takes no vitals');
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, 'f5400000-0000-4000-8000-000000000004', '{"pulse":70}'),
    '55000', 'a deleted patient takes no vitals');
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, gen_random_uuid(), '{"pulse":70}'),
    'P0002', 'an unknown visit is not found');
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, 'f5400000-0000-4000-8000-000000000002', '{"pulse":70}'),
    '42501', 'a nurse cannot record vitals for a branch outside her scope');

  -- Cross-tenant: tenant id from the session is checked against memberships; another tenant's visit id is not found.
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', beta, 'f5400000-0000-4000-8000-000000000005', '{"pulse":70}'),
    'P0002', 'a nurse cannot write into a tenant she is not a member of');
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, 'f5400000-0000-4000-8000-000000000005', '{"pulse":70}'),
    'P0002', 'another tenant''s visit id is not found in this tenant');
  perform tests.throws_ok(format('select clinical.list_vitals(%L, %L, null)', beta, 'bb000000-0000-4000-8000-000000000001'),
    'P0002', 'a nurse cannot read another tenant''s vitals');

  -- History, newest first; RLS lets the nurse read her branch.
  v := clinical.list_vitals(t, 'aa000000-0000-4000-8000-000000000001', null);
  perform tests.ok(jsonb_array_length(v) = 5 and (v -> 0 ->> 'recordedOn') >= (v -> 4 ->> 'recordedOn'),
    'patient history lists every reading, newest first');
  perform tests.ok(jsonb_array_length(clinical.list_vitals(t, null, q1)) = 5, 'visit history lists the visit''s readings');
  perform tests.throws_ok(format('select clinical.list_vitals(%L, null, null)', t), '22023', 'list needs a patient or a visit');
  perform tests.ok((select count(*) from clinical.vitals) = 5, 'RLS: the nurse sees her tenant''s readings');

  -- The doctor (same branch) sees them too and may record.
  perform pg_temp.act(doc);
  perform tests.ok(jsonb_array_length(clinical.list_vitals(t, null, q1)) = 5, 'the doctor sees the visit''s vitals');
  v := clinical.record_vitals(t, q1, '{"weightKg":61.25}');
  perform tests.ok(v ->> 'weightKg' = '61.3', 'a doctor may record vitals; weight rounds to 0.1 kg');

  -- Beta's doctor sees none of Alpha's rows.
  perform pg_temp.act('0b000000-0000-4000-8000-000000000002');
  perform tests.ok((select count(*) from clinical.vitals) = 0, 'RLS: another tenant sees no rows');

  -- Reception has no clinical permission.
  perform pg_temp.act('0a000000-0000-4000-8000-000000000002');
  perform tests.throws_ok(format('select clinical.record_vitals(%L, %L, %L::jsonb)', t, 'f5400000-0000-4000-8000-000000000002', '{"pulse":70}'),
    '42501', 'a receptionist cannot record vitals');
  perform tests.throws_ok(format('select clinical.list_vitals(%L, %L, null)', t, 'aa000000-0000-4000-8000-000000000001'),
    '42501', 'a receptionist cannot read vitals');
  perform tests.ok((select count(*) from clinical.vitals) = 0, 'RLS: reception reads no vitals rows');
  execute 'reset role';
end;
$$;

select tests.ok((select count(*) from audit.audit_log where schema_name = 'clinical' and table_name = 'vitals' and action = 'INSERT') = 6, 'each reading is written to the audit log');

rollback;
