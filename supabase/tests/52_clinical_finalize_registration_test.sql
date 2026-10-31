-- #128 (20261027120000): finalizing a prescription needs the doctor's council registration number.
-- Synthetic data only; the transaction rolls back.
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

insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values
  ('f5200000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5201, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'waiting');
update appointment.practitioners set registration_number = null, council_name = null
where id = 'c1111111-0000-4000-8000-000000000001';

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  doc uuid := '0d000000-0000-4000-8000-000000000001';
  v jsonb;
  cid uuid;
  rv int;
  n int;
begin
  perform pg_temp.act(doc);
  v := clinical.start_consultation(t, 'f5200000-0000-4000-8000-000000000001', null);
  cid := (v ->> 'id')::uuid;
  v := clinical.save_consultation(t, cid, (v ->> 'rowVersion')::int, '{"chiefComplaint":"Zz-QA cough"}'::jsonb);
  rv := (v ->> 'rowVersion')::int;

  perform tests.throws_ok(format($q$select clinical.finalize_consultation(%L, %L, %s)$q$, t, cid, rv), '22023',
    'a doctor with no registration number cannot finalize');
  execute 'reset role';
  perform tests.ok((select status = 'draft' from clinical.consultations where id = cid)
    and not exists (select 1 from messaging.outbox where aggregate_id = cid),
    'the refused finalize leaves a draft and emits no event');

  update appointment.practitioners set registration_number = 'NMC/5200001', council_name = 'Synthetic Council'
  where id = 'c1111111-0000-4000-8000-000000000001';
  perform pg_temp.act(doc);
  v := clinical.finalize_consultation(t, cid, rv);
  perform tests.ok(v ->> 'status' = 'finalized', 'once the registration number is set, finalize succeeds');
  v := clinical.consultation_print(t, cid);
  perform tests.ok(v -> 'doctor' ->> 'registrationNumber' = 'NMC/5200001' and v -> 'doctor' ->> 'council' = 'Synthetic Council'
    and v -> 'patient' ? 'sex' and v -> 'patient' ? 'dateOfBirth',
    'the print payload carries registration, council, patient sex and date of birth');
  -- 20261031235000: paper size comes from the tenant setting (config default A5), A4 when the hospital sets it.
  perform tests.ok(v ->> 'paperSize' in ('A5', 'A4'), 'the print payload carries the configured paper size (never empty)');
  execute 'reset role';
  insert into appointment.tenant_settings (tenant_id, rx_paper_size, created_by, updated_by)
    values (t, 'A4', doc, doc)
    on conflict (tenant_id) do update set rx_paper_size = 'A4';
  perform pg_temp.act(doc);
  v := clinical.consultation_print(t, cid);
  perform tests.ok(v ->> 'paperSize' = 'A4', 'a hospital set to A4 letterhead prints A4');
  execute 'reset role';
  perform tests.throws_ok($q$update appointment.tenant_settings set rx_paper_size = 'Letter'$q$, '23514', 'only A5 or A4 are accepted');
  perform pg_temp.act(doc);

  execute 'reset role';
  update appointment.practitioners set registration_number = null where id = 'c1111111-0000-4000-8000-000000000001';
  perform pg_temp.act(doc);
  v := clinical.finalize_consultation(t, cid, rv);
  perform tests.ok(v ->> 'status' = 'finalized', 'a repeat finalize of an already-finalized prescription still answers');
  execute 'reset role';
  select count(*) into n from messaging.outbox where aggregate_id = cid and event_type = 'consultation.finalized';
  perform tests.ok(n = 1, 'exactly one finalize event');
end;
$$;

rollback;
