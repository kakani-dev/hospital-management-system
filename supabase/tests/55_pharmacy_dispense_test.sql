-- #106 PR1: pharmacist queue, prescription detail, FEFO dispensing (20261027150000). Synthetic Zz-QA data; rolls back.
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
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'pharmacy' and c.relname in ('dispense', 'dispense_line'))
  and not has_table_privilege('hms_svc_inventory', 'pharmacy.dispense', 'select')
  and not has_table_privilege('hms_svc_inventory', 'pharmacy.dispense_line', 'insert')
  and not has_table_privilege('hms_svc_inventory', 'clinical.consultations', 'select')
  and not has_table_privilege('hms_svc_inventory', 'patient.patients', 'select')
  and has_function_privilege('hms_svc_inventory', 'pharmacy.dispense(uuid, uuid, jsonb)', 'execute')
  and not has_function_privilege('hms_svc_billing', 'pharmacy.dispense(uuid, uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'pharmacy.list_queue(uuid, uuid, text)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'pharmacy.load_rx(uuid, uuid, boolean)', 'execute'),
  'pharmacy tables are closed; only the three commands are granted, to the inventory service');
select tests.ok(
  (select array_agg(role::text order by role) from identity.role_permissions where permission = 'pharmacy.dispense')
    = array['pharmacist', 'tenant_admin']
  and (select array_agg(role::text order by role) from identity.role_permissions where permission = 'pharmacy.view')
    = array['pharmacist', 'tenant_admin'],
  'only pharmacist and tenant_admin see the queue and dispense');

-- Fixtures: Zz-QA pharmacist at Alpha East, an Alpha East pharmacy and an unlicensed ward store,
-- one drug with three batches (one expired), finalized prescriptions at East and Main.
insert into auth.users (id, email) values
  ('0e550000-0000-4000-8000-000000000001', 'zz-qa-pharmacist-55@synthetic.example'),
  ('0e550000-0000-4000-8000-000000000002', 'zz-qa-pharmacist-main-55@synthetic.example');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e550000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 'pharmacist', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0e550000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 'pharmacist', 'active');
update appointment.practitioners set registration_number = 'NMC/5500001' where id = 'c1111111-0000-4000-8000-000000000001';
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values
  ('f5500000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   (date '2035-08-01' + tests.fwd_days()), 5501, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   (date '2035-08-01' + tests.fwd_days()), 5502, 'aa000000-0000-4000-8000-000000000004', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
   (date '2035-08-01' + tests.fwd_days()), 5503, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   (date '2035-08-01' + tests.fwd_days()), 5504, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done');

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  admin uuid := '0a000000-0000-4000-8000-000000000001';
  item jsonb;
  item2 jsonb;
  st jsonb;
  ward jsonb;
begin
  perform pg_temp.act(admin);
  item := inventory.create_item(t, jsonb_build_object('itemKind', 'drug', 'brandName', 'Zz-QA Amoxy 500',
    'genericName', 'Zz-QA Amoxicillin', 'strength', '500 mg', 'dosageForm', 'capsule', 'manufacturerName', 'Zz-QA Labs',
    'scheduleCode', 'H', 'hsnCode', '30041010', 'gstRateBp', 1200, 'baseUomCode', 'CAP'));
  item2 := inventory.create_item(t, jsonb_build_object('itemKind', 'drug', 'brandName', 'Zz-QA Para 650',
    'genericName', 'Zz-QA Paracetamol', 'strength', '650 mg', 'dosageForm', 'tablet', 'manufacturerName', 'Zz-QA Labs',
    'scheduleCode', 'OTC', 'hsnCode', '30049099', 'gstRateBp', 1200, 'baseUomCode', 'TAB'));
  st := inventory.create_store(t, jsonb_build_object('branchId', 'a1111111-0000-4000-8000-000000000002',
    'name', 'Zz-QA East OP Pharmacy', 'storeKind', 'op_pharmacy', 'drugLicenceNo', 'ZZ-DL-55', 'licenceValidTo', '2099-01-01'));
  ward := inventory.create_store(t, jsonb_build_object('branchId', 'a1111111-0000-4000-8000-000000000002',
    'name', 'Zz-QA East Ward', 'storeKind', 'ward'));
  perform inventory.post_opening_stock(t, 'e5500000-0000-4000-8000-000000000001', jsonb_build_object(
    'storeId', st ->> 'id', 'lines', jsonb_build_array(
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-LATE', 'expiryDate', (date '2031-12-31' + tests.fwd_days()), 'mrpPaise', 900, 'purchaseRatePaise', 500, 'qtyBase', 50),
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-SOON', 'expiryDate', (date '2030-01-31' + tests.fwd_days()), 'mrpPaise', 900, 'purchaseRatePaise', 450, 'qtyBase', 6),
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-EXPIRED', 'expiryDate', '2020-01-31', 'mrpPaise', 900, 'purchaseRatePaise', 400, 'qtyBase', 100),
      jsonb_build_object('itemId', item2 ->> 'id', 'batchNo', 'ZZ-P1', 'expiryDate', (date '2032-01-31' + tests.fwd_days()), 'mrpPaise', 200, 'purchaseRatePaise', 100, 'qtyBase', 4))));
  execute 'reset role';
  perform set_config('zz.item', item ->> 'id', true);
  perform set_config('zz.item2', item2 ->> 'id', true);
  perform set_config('zz.store', st ->> 'id', true);
  perform set_config('zz.ward', ward ->> 'id', true);
end;
$$;

-- Consultations straight into the tables (the doctor flow is covered by 47): rx1 oldest at East
-- (two lines, one with a linked item), rx2 at East, rx3 at Main, rx4 a draft.
insert into clinical.consultations (id, tenant_id, branch_id, patient_id, practitioner_id, queue_entry_id, root_id, status, created_by, updated_by)
values
  ('c5500000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'f5500000-0000-4000-8000-000000000001', 'c5500000-0000-4000-8000-000000000001', 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'),
  ('c5500000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004', 'c1111111-0000-4000-8000-000000000001', 'f5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000002', 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'),
  ('c5500000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'f5500000-0000-4000-8000-000000000003', 'c5500000-0000-4000-8000-000000000003', 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'),
  ('c5500000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'f5500000-0000-4000-8000-000000000004', 'c5500000-0000-4000-8000-000000000004', 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001');
insert into clinical.prescription_lines (tenant_id, consultation_id, line_no, medicine_name, inventory_item_id, dose, frequency, duration_days, created_by, updated_by)
select '11111111-1111-4111-8111-111111111111', c, n, m, i, '1 cap', '1-0-1', 10, '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'
from (values
  ('c5500000-0000-4000-8000-000000000001'::uuid, 1, 'Amoxicillin 500', current_setting('zz.item')::uuid),
  ('c5500000-0000-4000-8000-000000000001'::uuid, 2, 'Paracetamol 650', null::uuid),
  ('c5500000-0000-4000-8000-000000000002'::uuid, 1, 'Amoxicillin 500', current_setting('zz.item')::uuid),
  ('c5500000-0000-4000-8000-000000000003'::uuid, 1, 'Amoxicillin 500', current_setting('zz.item')::uuid),
  ('c5500000-0000-4000-8000-000000000004'::uuid, 1, 'Amoxicillin 500', current_setting('zz.item')::uuid)) v(c, n, m, i);
update clinical.consultations set status = 'finalized', finalized_on = now() - interval '2 hours', finalized_by = '0d000000-0000-4000-8000-000000000001'
where id = 'c5500000-0000-4000-8000-000000000001';
update clinical.consultations set status = 'finalized', finalized_on = now() - interval '1 hour', finalized_by = '0d000000-0000-4000-8000-000000000001'
where id in ('c5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000003');

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  ph uuid := '0e550000-0000-4000-8000-000000000001';
  rx1 uuid := 'c5500000-0000-4000-8000-000000000001';
  rx2 uuid := 'c5500000-0000-4000-8000-000000000002';
  store uuid := current_setting('zz.store')::uuid;
  ward uuid := current_setting('zz.ward')::uuid;
  item2 uuid := current_setting('zz.item2')::uuid;
  q jsonb;
  v jsonb;
  v2 jsonb;
  k1 uuid := 'e5500000-0000-4000-8000-0000000000a1';
  st text;
begin
  perform pg_temp.act(ph);

  -- Queue: East only (pharmacist scope), finalized only, oldest first, open by default.
  q := pharmacy.list_queue(t, null, null);
  perform tests.ok(jsonb_array_length(q) = 2 and (q -> 0 ->> 'id')::uuid = rx1 and (q -> 1 ->> 'id')::uuid = rx2,
    'queue lists the branch''s finalized prescriptions oldest first; drafts and other branches are hidden');
  perform tests.ok(q -> 0 ->> 'status' = 'pending' and q -> 0 ->> 'patientName' = 'Ravi Synthetic-Alpha'
    and q -> 0 ->> 'patientMrn' = 'ALP-0002' and q -> 0 ->> 'doctorName' is not null and (q -> 0 ->> 'lineCount')::int = 2,
    'queue rows carry patient, MRN, doctor, line count and status');
  begin
    perform pharmacy.list_queue(t, 'a1111111-0000-4000-8000-000000000001', null);
    perform tests.ok(false, 'another branch queue is refused');
  exception when sqlstate '42501' then perform tests.ok(true, 'another branch queue is refused');
  end;
  begin
    perform pharmacy.list_queue(t, null, 'bogus');
    perform tests.ok(false, 'unknown status filter is a 400');
  exception when sqlstate '22023' then perform tests.ok(true, 'unknown status filter is a 400');
  end;

  -- Detail with availability (expired batch excluded: 50 + 6).
  v := pharmacy.get_prescription(t, rx1, store);
  perform tests.ok((v -> 'lines' -> 0 ->> 'availableBase')::int = 56 and v -> 'lines' -> 1 -> 'availableBase' = 'null'::jsonb,
    'detail shows unexpired stock for linked lines');
  begin
    perform pharmacy.get_prescription(t, 'c5500000-0000-4000-8000-000000000004', null);
    perform tests.ok(false, 'a draft is not visible to the pharmacy');
  exception when sqlstate 'P0002' then perform tests.ok(true, 'a draft is not visible to the pharmacy');
  end;
  begin
    perform pharmacy.get_prescription(t, 'c5500000-0000-4000-8000-000000000003', null);
    perform tests.ok(false, 'a prescription at another branch is refused');
  exception when sqlstate '42501' then perform tests.ok(true, 'a prescription at another branch is refused');
  end;

  -- Validation.
  begin
    perform pharmacy.dispense(t, null, jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'missing idempotency key');
  exception when sqlstate '22023' then perform tests.ok(true, 'missing idempotency key');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[]'::jsonb));
    perform tests.ok(false, 'no lines');
  exception when sqlstate '22023' then perform tests.ok(true, 'no lines');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":0}]'::jsonb));
    perform tests.ok(false, 'zero quantity');
  exception when sqlstate '22023' then perform tests.ok(true, 'zero quantity');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1.5}]'::jsonb));
    perform tests.ok(false, 'fractional quantity');
  exception when sqlstate '22023' then perform tests.ok(true, 'fractional quantity');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1},{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'duplicate line');
  exception when sqlstate '22023' then perform tests.ok(true, 'duplicate line');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":9,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'line not on the prescription');
  exception when sqlstate '22023' then perform tests.ok(true, 'line not on the prescription');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":2,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'unlinked line needs an item');
  exception when sqlstate '22023' then perform tests.ok(true, 'unlinked line needs an item');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', ward, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'a ward store cannot dispense');
  exception when sqlstate '22023' then perform tests.ok(true, 'a ward store cannot dispense');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', 'c5500000-0000-4000-8000-000000000003', 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'another branch prescription cannot be dispensed');
  exception when sqlstate '42501' then perform tests.ok(true, 'another branch prescription cannot be dispensed');
  end;

  -- Stock-out: 57 asked, only 56 unexpired (the expired 100 do not count).
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":57}]'::jsonb));
    perform tests.ok(false, 'stock-out is refused');
  exception when sqlstate '55000' then perform tests.ok(true, 'stock-out is refused (expired stock is never used)');
  end;
  execute 'reset role';
  perform tests.ok(not exists (select 1 from pharmacy.dispense d where d.consultation_id = rx1), 'a refused dispense writes nothing');
  perform pg_temp.act(ph);

  -- Partial dispense of line 1 (FEFO: 6 from ZZ-SOON, then 4 from ZZ-LATE), line 2 with a chosen item.
  v := pharmacy.dispense(t, k1, jsonb_build_object('consultationId', rx1, 'storeId', store,
    'lines', jsonb_build_array(jsonb_build_object('lineNo', 1, 'qtyBase', 10, 'complete', false),
                               jsonb_build_object('lineNo', 2, 'qtyBase', 4, 'itemId', item2))));
  perform tests.ok(v ->> 'status' = 'partial' and (v -> 'lines' -> 0 ->> 'dispensedBase')::int = 10
    and (v -> 'lines' -> 0 ->> 'complete')::boolean = false and (v -> 'lines' -> 1 ->> 'complete')::boolean = true,
    'partial dispense: line 1 open with 10 given, line 2 complete');
  perform tests.ok(
    (v -> 'dispenses' -> 0 -> 'lines' -> 0 ->> 'batchNo') = 'ZZ-SOON' and (v -> 'dispenses' -> 0 -> 'lines' -> 0 ->> 'qtyBase')::int = 6
    and (v -> 'dispenses' -> 0 -> 'lines' -> 1 ->> 'batchNo') = 'ZZ-LATE' and (v -> 'dispenses' -> 0 -> 'lines' -> 1 ->> 'qtyBase')::int = 4,
    'FEFO takes the earliest unexpired batch first, then the next');
  perform tests.ok((v -> 'lines' -> 0 ->> 'availableBase')::int = 46, 'stock on hand drops by what was dispensed');

  -- Replay with the same key returns the same state and moves no more stock.
  v2 := pharmacy.dispense(t, k1, jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":40}]'::jsonb));
  perform tests.ok(jsonb_array_length(v2 -> 'dispenses') = 1 and (v2 -> 'lines' -> 0 ->> 'dispensedBase')::int = 10,
    'a replayed key returns the first dispense and moves no stock');

  -- Double dispense of a completed line.
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store,
      'lines', jsonb_build_array(jsonb_build_object('lineNo', 2, 'qtyBase', 1, 'itemId', item2))));
    perform tests.ok(false, 'double dispense is refused');
  exception when sqlstate '55000' then perform tests.ok(true, 'double dispense of a completed line is refused');
  end;

  q := pharmacy.list_queue(t, null, 'partial');
  perform tests.ok(jsonb_array_length(q) = 1 and (q -> 0 ->> 'id')::uuid = rx1, 'queue filter: partial');

  -- Finish line 1; the prescription leaves the open queue.
  v := pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":5}]'::jsonb));
  perform tests.ok(v ->> 'status' = 'dispensed' and (v -> 'lines' -> 0 ->> 'dispensedBase')::int = 15, 'completing the last line marks it dispensed');
  q := pharmacy.list_queue(t, null, null);
  perform tests.ok(jsonb_array_length(q) = 1 and (q -> 0 ->> 'id')::uuid = rx2, 'a dispensed prescription leaves the open queue');
  q := pharmacy.list_queue(t, null, 'dispensed');
  perform tests.ok(jsonb_array_length(q) = 1 and (q -> 0 ->> 'id')::uuid = rx1, 'queue filter: dispensed');

  -- Cross-tenant: the pharmacist is not a Beta member.
  begin
    perform pharmacy.list_queue('22222222-2222-4222-8222-222222222222', null, null);
    perform tests.ok(false, 'cross-tenant queue');
  exception when sqlstate 'P0002' then perform tests.ok(true, 'another tenant''s queue is not found');
  end;
  begin
    perform pharmacy.dispense('22222222-2222-4222-8222-222222222222', gen_random_uuid(),
      jsonb_build_object('consultationId', rx2, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'cross-tenant dispense');
  exception when sqlstate 'P0002' then perform tests.ok(true, 'dispensing under another tenant is not found');
  end;

  -- Reception and doctor cannot use the pharmacy.
  perform pg_temp.act('0a000000-0000-4000-8000-000000000002');
  begin
    perform pharmacy.list_queue(t, null, null);
    perform tests.ok(false, 'reception cannot see the pharmacy queue');
  exception when sqlstate '42501' then perform tests.ok(true, 'reception cannot see the pharmacy queue');
  end;
  perform pg_temp.act('0d000000-0000-4000-8000-000000000001');
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'a doctor cannot dispense');
  exception when sqlstate '42501' then perform tests.ok(true, 'a doctor cannot dispense');
  end;

  -- Admin can dispense too.
  perform pg_temp.act('0a000000-0000-4000-8000-000000000001');
  v := pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":2}]'::jsonb));
  perform tests.ok(v ->> 'status' = 'dispensed', 'tenant admin can dispense');
  execute 'reset role';
end;
$$;

-- Ledger and audit trail.
select tests.ok(
  (select count(*) from inventory.stock_ledger where source_type = 'pharmacy_dispense' and movement = 'dispense') = 5
  and (select sum(qty_delta_base) from inventory.stock_ledger where source_type = 'pharmacy_dispense') = -21
  and (select unit_cost_paise from inventory.stock_ledger l join inventory.batch b on b.id = l.batch_id
       where l.source_type = 'pharmacy_dispense' and b.batch_no = 'ZZ-SOON') = 450,
  'every dispensed batch is a dispense ledger row at the batch purchase cost');
select tests.ok(
  (select c.on_hand_base from inventory.stock_balance_cache c join inventory.batch b on b.id = c.batch_id where b.batch_no = 'ZZ-SOON') = 0
  and (select c.on_hand_base from inventory.stock_balance_cache c join inventory.batch b on b.id = c.batch_id where b.batch_no = 'ZZ-LATE') = 39
  and (select c.on_hand_base from inventory.stock_balance_cache c join inventory.batch b on b.id = c.batch_id where b.batch_no = 'ZZ-EXPIRED') = 100,
  'balances follow the ledger and the expired batch is untouched');
select tests.ok(
  (select count(*) from audit.audit_log where schema_name = 'pharmacy' and table_name = 'dispense' and action = 'INSERT') = 3
  and (select count(*) from audit.audit_log where schema_name = 'pharmacy' and table_name = 'dispense_line' and action = 'INSERT') = 5,
  'dispenses and their lines are in the audit log');
select tests.throws_ok($$update pharmacy.dispense_line set qty_base = 1$$, '55000', 'dispense lines are append-only');
select tests.throws_ok($$delete from pharmacy.dispense$$, '55000', 'dispenses cannot be deleted');

rollback;
