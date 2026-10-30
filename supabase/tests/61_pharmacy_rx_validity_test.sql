-- #188: prescriptions expire for dispensing (20261030120000_inventory_pharmacy_rx_validity). Synthetic Zz-QA data; rolls back.
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
   '2035-08-01', 5501, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5502, 'aa000000-0000-4000-8000-000000000004', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
   '2035-08-01', 5503, 'aa000000-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001', 'done'),
  ('f5500000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
   '2035-08-01', 5504, 'aa000000-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001', 'done');

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
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-LATE', 'expiryDate', '2031-12-31', 'mrpPaise', 900, 'purchaseRatePaise', 500, 'qtyBase', 50),
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-SOON', 'expiryDate', '2030-01-31', 'mrpPaise', 900, 'purchaseRatePaise', 450, 'qtyBase', 6),
      jsonb_build_object('itemId', item ->> 'id', 'batchNo', 'ZZ-EXPIRED', 'expiryDate', '2020-01-31', 'mrpPaise', 900, 'purchaseRatePaise', 400, 'qtyBase', 100),
      jsonb_build_object('itemId', item2 ->> 'id', 'batchNo', 'ZZ-P1', 'expiryDate', '2032-01-31', 'mrpPaise', 200, 'purchaseRatePaise', 100, 'qtyBase', 4))));
  execute 'reset role';
  perform set_config('zz.item', item ->> 'id', true);
  perform set_config('zz.item2', item2 ->> 'id', true);
  perform set_config('zz.store', st ->> 'id', true);
  perform set_config('zz.ward', ward ->> 'id', true);
end;
$$;

-- rx1 finalized 30 local days ago (last valid day is today), rx2 31 days ago (expired yesterday),
-- rx3 at Main finalized 31 days ago. Times are pinned to noon branch-local so the day is unambiguous.
insert into clinical.consultations (id, tenant_id, branch_id, patient_id, practitioner_id, queue_entry_id, root_id, status, created_by, updated_by)
select c, '11111111-1111-4111-8111-111111111111', b, p, 'c1111111-0000-4000-8000-000000000001', q, c, 'draft', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'
from (values
  ('c5500000-0000-4000-8000-000000000001'::uuid, 'a1111111-0000-4000-8000-000000000002'::uuid, 'aa000000-0000-4000-8000-000000000002'::uuid, 'f5500000-0000-4000-8000-000000000001'::uuid),
  ('c5500000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004', 'f5500000-0000-4000-8000-000000000002'),
  ('c5500000-0000-4000-8000-000000000003', 'a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'f5500000-0000-4000-8000-000000000003')) v(c, b, p, q);
insert into clinical.prescription_lines (tenant_id, consultation_id, line_no, medicine_name, inventory_item_id, dose, frequency, duration_days, created_by, updated_by)
select '11111111-1111-4111-8111-111111111111', c, 1, 'Amoxicillin 500', current_setting('zz.item')::uuid, '1 cap', '1-0-1', 5,
  '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001'
from unnest(array['c5500000-0000-4000-8000-000000000001', 'c5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000003']::uuid[]) c;
create or replace function pg_temp.local_noon(p_branch uuid, p_days_ago integer) returns timestamptz language sql as $$
  select ((inventory.branch_today(p_branch) - p_days_ago)::timestamp + time '12:00') at time zone
    coalesce((select coalesce(b.timezone_override, t.time_zone) from identity.branches b join identity.tenants t on t.id = b.tenant_id where b.id = p_branch), 'Asia/Kolkata')
$$;
update clinical.consultations set status = 'finalized', finalized_by = '0d000000-0000-4000-8000-000000000001',
  finalized_on = pg_temp.local_noon(branch_id, case id when 'c5500000-0000-4000-8000-000000000001' then 30 else 31 end)
where id in ('c5500000-0000-4000-8000-000000000001', 'c5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000003');

select tests.ok(pharmacy.rx_validity_days('11111111-1111-4111-8111-111111111111') = 30, 'default validity is 30 days');
select tests.ok(not has_function_privilege('authenticated', 'pharmacy.set_rx_validity_days(uuid, integer)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'pharmacy.rx_valid_through(uuid, uuid, timestamptz)', 'execute')
  and has_function_privilege('hms_svc_inventory', 'pharmacy.set_rx_validity_days(uuid, integer)', 'execute')
  and (select relrowsecurity from pg_class where oid = 'pharmacy.tenant_setting'::regclass)
  and not has_table_privilege('hms_svc_inventory', 'pharmacy.tenant_setting', 'select'),
  'setting table is closed; helpers are internal');

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  ph uuid := '0e550000-0000-4000-8000-000000000001';
  admin uuid := '0a000000-0000-4000-8000-000000000001';
  rx1 uuid := 'c5500000-0000-4000-8000-000000000001';
  rx2 uuid := 'c5500000-0000-4000-8000-000000000002';
  store uuid := current_setting('zz.store')::uuid;
  v jsonb;
  ids uuid[];
  k uuid := gen_random_uuid();
begin
  perform pg_temp.act(ph);
  select array_agg((e ->> 'id')::uuid) into ids from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e;
  perform tests.ok(rx1 = any(ids) and not rx2 = any(ids), 'open queue: day 30 shown, day 31 hidden');
  select array_agg((e ->> 'id')::uuid) into ids from jsonb_array_elements(pharmacy.list_queue(t, null, 'pending')) e;
  perform tests.ok(not rx2 = any(ids), 'pending filter hides expired too');
  v := (select e from jsonb_array_elements(pharmacy.list_queue(t, null, 'all')) e where e ->> 'id' = rx2::text);
  perform tests.ok(v is not null and (v ->> 'expired')::boolean
    and (v ->> 'validThrough')::date = inventory.branch_today('a1111111-0000-4000-8000-000000000002') - 1,
    'all keeps expired with validThrough = yesterday');
  v := (select e from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e where e ->> 'id' = rx1::text);
  perform tests.ok(not (v ->> 'expired')::boolean and (v ->> 'validThrough')::date = inventory.branch_today('a1111111-0000-4000-8000-000000000002'),
    'day 30: valid through today');

  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx2, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":2}]'::jsonb));
    perform tests.ok(false, 'day 31 dispense refused');
  exception when sqlstate '55000' then
    perform tests.ok(sqlerrm = 'prescription expired on ' || to_char(inventory.branch_today('a1111111-0000-4000-8000-000000000002') - 1, 'YYYY-MM-DD'),
      'day 31 dispense raises 55000 with the expiry date: ' || sqlerrm);
  end;
  v := pharmacy.dispense(t, k, jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":2,"complete":false}]'::jsonb));
  perform tests.ok((v -> 'lines' -> 0 ->> 'dispensedBase')::int = 2, 'day 30 dispense allowed');

  -- Setting change: pharmacist cannot; admin shortens to 29 days, rx1 now expired; replay of an earlier key still answers.
  begin
    perform pharmacy.set_rx_validity_days(t, 60);
    perform tests.ok(false, 'pharmacist cannot change validity');
  exception when sqlstate '42501' then perform tests.ok(true, 'pharmacist cannot change validity');
  end;
  perform pg_temp.act(admin);
  begin
    perform pharmacy.set_rx_validity_days(t, 0);
    perform tests.ok(false, 'zero days refused');
  exception when sqlstate '22023' then perform tests.ok(true, 'validity outside 1..365 refused');
  end;
  begin
    perform pharmacy.set_rx_validity_days('22222222-2222-4222-8222-222222222222', 60);
    perform tests.ok(false, 'other tenant refused');
  exception when sqlstate '42501' then perform tests.ok(true, 'admin cannot set another tenant');
  end;
  perform pharmacy.set_rx_validity_days(t, 29);
  perform tests.ok((pharmacy.get_settings(t) ->> 'rxValidityDays')::int = 29, 'admin sets 29 days');
  perform pg_temp.act(ph);
  select array_agg((e ->> 'id')::uuid) into ids from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e;
  perform tests.ok(ids is null or not rx1 = any(ids), 'after shortening, the day-30 Rx leaves the queue');
  begin
    perform pharmacy.dispense(t, gen_random_uuid(), jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":1}]'::jsonb));
    perform tests.ok(false, 'shortened validity refuses');
  exception when sqlstate '55000' then perform tests.ok(true, 'after shortening, dispense is refused');
  end;
  v := pharmacy.dispense(t, k, jsonb_build_object('consultationId', rx1, 'storeId', store, 'lines', '[{"lineNo":1,"qtyBase":2,"complete":false}]'::jsonb));
  perform tests.ok((v -> 'lines' -> 0 ->> 'dispensedBase')::int = 2, 'idempotent replay of an earlier dispense still returns it');
  perform pg_temp.act(admin);
  perform pharmacy.set_rx_validity_days(t, 60);
  perform pg_temp.act(ph);
  select array_agg((e ->> 'id')::uuid) into ids from jsonb_array_elements(pharmacy.list_queue(t, null, 'open')) e;
  perform tests.ok(rx2 = any(ids), 'lengthening to 60 days brings day 31 back');
  execute 'reset role';
end;
$$;

rollback;
