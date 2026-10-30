-- #187: dispensing is capped at the prescribed quantity (20261030090000). Synthetic Zz-QA data; rolls back.
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
select '11111111-1111-4111-8111-111111111111', c, n, m, i, '1 cap', '1-0-1', 5, '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'
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

select tests.ok(pharmacy.prescribed_qty('1 cap', '1-0-1', 5) = 10, '1-0-1 for 5 days is 10');
select tests.ok(pharmacy.prescribed_qty('1 tab', '1 - 1 - 1 - 1', 3) = 12, 'four-slot pattern with spaces');
select tests.ok(pharmacy.prescribed_qty('1 tab', '0.5-0-0.5', 3) = 3, 'half tablets round up per course');
select tests.ok(pharmacy.prescribed_qty('2 tabs', 'BD', 5) = 20, 'BD with a two-tablet dose');
select tests.ok(pharmacy.prescribed_qty('5 ml', 'tds', 2) = 6, 'word codes are case-insensitive; liquids count doses');
select tests.ok(pharmacy.prescribed_qty('1 tab', 'SOS', 5) is null and pharmacy.prescribed_qty('1 tab', 'as advised', 5) is null,
  'SOS and free text have no derivable cap');
select tests.ok(not has_function_privilege('authenticated', 'pharmacy.prescribed_qty(text, text, integer)', 'execute'),
  'the helper is not exposed to clients');

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  ph uuid := '0e550000-0000-4000-8000-000000000001';
  rx1 uuid := 'c5500000-0000-4000-8000-000000000001';
  rx2 uuid := 'c5500000-0000-4000-8000-000000000002';
  store uuid := current_setting('zz.store')::uuid;
  v jsonb;
begin
  perform pg_temp.act(ph);
  v := pharmacy.get_prescription(t, rx1, store);
  perform tests.ok((v -> 'lines' -> 0 ->> 'prescribedBase')::int = 10, 'detail shows the prescribed quantity');

  -- Over by one in a single go.
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":11}]'::jsonb));
    perform tests.ok(false, 'over the prescription by one is refused');
  exception when sqlstate '55000' then perform tests.ok(true, 'over the prescription by one is refused');
  end;
  -- Partial, then the rest exactly, then nothing more.
  v := pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":4,"complete":false}]'::jsonb));
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":7}]'::jsonb));
    perform tests.ok(false, 'partial then over is refused');
  exception when sqlstate '55000' then perform tests.ok(true, 'repeated partial dispenses cannot add up past the prescription');
  end;
  -- 6 more spans two batches (2 left in ZZ-SOON, then ZZ-LATE) and lands exactly on 10.
  v := pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":6,"complete":false}]'::jsonb));
  perform tests.ok((v -> 'lines' -> 0 ->> 'dispensedBase')::int = 10 and jsonb_array_length(v -> 'dispenses' -> 1 -> 'lines') = 2,
    'the exact prescribed total is allowed across multiple batches');

  -- Override path.
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store,
      'lines', '[{"lineNo":1,"qtyBase":12,"overrideReason":"short"}]'::jsonb));
    perform tests.ok(false, 'a too-short reason is refused');
  exception when sqlstate '22023' then perform tests.ok(true, 'an override reason under 10 characters is refused');
  end;
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store,
      'lines', '[{"lineNo":1,"qtyBase":12,"overrideReason":42}]'::jsonb));
    perform tests.ok(false, 'a non-text reason is refused');
  exception when sqlstate '22023' then perform tests.ok(true, 'a non-text override reason is refused');
  end;
  v := pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store,
    'lines', '[{"lineNo":1,"qtyBase":12,"overrideReason":"Zz-QA strip of 12 cannot be split"}]'::jsonb));
  perform tests.ok((v -> 'lines' -> 0 ->> 'dispensedBase')::int = 12
    and v -> 'dispenses' -> 0 -> 'lines' -> 0 ->> 'overrideReason' = 'Zz-QA strip of 12 cannot be split',
    'over the prescription with a reason is allowed and the reason is shown');
  execute 'reset role';
end;
$$;

select tests.ok(
  (select count(*) from audit.audit_log a where a.schema_name = 'pharmacy' and a.table_name = 'dispense_line'
     and a.action = 'INSERT' and a.new_data ->> 'over_rx_reason' = 'Zz-QA strip of 12 cannot be split') >= 1
  and (select count(*) from pharmacy.dispense_line where over_rx_reason is not null)
      = (select count(*) from pharmacy.dispense_line dl join clinical.prescription_lines l on l.id = dl.prescription_line_id
         where l.consultation_id = 'c5500000-0000-4000-8000-000000000002'),
  'override reasons are stored only when used and are in the audit log');

rollback;
