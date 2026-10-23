-- Inventory foundation: roles, immutable ledger, opening stock, FEFO, and generated codes.
begin;

select tests.as_superuser();

select tests.ok(
  (select not rolcanlogin and not rolinherit from pg_roles where rolname = 'hms_svc_inventory')
  and not pg_has_role('hms_svc_inventory', 'authenticated', 'member')
  and pg_has_role('hms_inventory_login', 'hms_svc_inventory', 'member')
  and not pg_has_role('hms_inventory_login', 'hms_svc_billing', 'member')
  and not pg_has_role('hms_billing_login', 'hms_svc_inventory', 'member'),
  'inventory group role is NOLOGIN NOINHERIT and only its own login is a member');

select tests.ok(
  has_table_privilege('hms_svc_inventory', 'inventory.item', 'select')
  and not has_table_privilege('hms_svc_inventory', 'inventory.item', 'insert')
  and not has_table_privilege('hms_svc_inventory', 'inventory.item', 'update')
  and not has_table_privilege('hms_svc_inventory', 'inventory.item', 'delete')
  and not has_table_privilege('hms_svc_inventory', 'inventory.stock_ledger', 'update')
  and not has_table_privilege('hms_svc_inventory', 'inventory.stock_ledger', 'delete')
  and not has_table_privilege('hms_svc_inventory', 'inventory.stock_balance_cache', 'insert')
  and not has_table_privilege('hms_svc_inventory', 'inventory.code_seq', 'select')
  and not has_table_privilege('hms_svc_billing', 'inventory.item', 'select')
  and not has_table_privilege('hms_svc_patients', 'inventory.store', 'select')
  and not has_table_privilege('hms_svc_inventory', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_inventory', 'billing.bill', 'select')
  and not has_function_privilege('hms_svc_billing', 'inventory.fefo_pick_v1(uuid, uuid, uuid, bigint)', 'execute')
  and has_function_privilege('hms_svc_inventory', 'inventory.fefo_pick_v1(uuid, uuid, uuid, bigint)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'inventory.next_code(uuid, text, text)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'patient.patient_exists_v1(uuid, uuid)', 'execute'),
  'inventory can read its own tables and FEFO, and cannot touch another service');

select tests.ok(
  (select count(*) from inventory.uom) = 9
  and not exists (
    select 1 from information_schema.columns
    where table_schema = 'inventory' and table_name = 'item' and column_name = 'reorder_level')
  and not exists (
    select 1 from information_schema.columns
    where table_schema = 'inventory' and table_name = 'batch' and column_name = 'purchase_rate_paise'),
  'units are seeded, reorder level is not on the item, and purchase rate is not on the batch');

select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);

select tests.throws_ok(
  $$select inventory.create_item(
      '11111111-1111-4111-8111-111111111111',
      '{"code":"PARA","itemKind":"drug","brandName":"Para","genericName":"Paracetamol","manufacturerName":"Acme","hsnCode":"3004","gstRateBp":1200,"baseUomCode":"TAB"}'::jsonb)$$,
  '22023',
  'a client cannot supply an item code');

select tests.throws_ok(
  $$select inventory.create_store(
      '11111111-1111-4111-8111-111111111111',
      '{"storeCode":"MAIN","branchId":"a1111111-0000-4000-8000-000000000001","name":"Main","storeKind":"main"}'::jsonb)$$,
  '22023',
  'a client cannot supply a store code');

select inventory.create_item(
  '11111111-1111-4111-8111-111111111111',
  jsonb_build_object(
    'itemKind', 'drug',
    'brandName', 'Crocin',
    'genericName', 'Paracetamol',
    'strength', '500 mg',
    'dosageForm', 'tablet',
    'manufacturerName', 'Acme',
    'scheduleCode', 'H',
    'hsnCode', '30049099',
    'gstRateBp', 1200,
    'baseUomCode', 'TAB',
    'packs', jsonb_build_array(jsonb_build_object('uomCode', 'STRIP', 'unitsPerPack', 10, 'isPurchase', true, 'isSale', true))
  ));

select tests.ok(
  (select code from inventory.item where brand_name = 'Crocin') = 'ITM-0001'
  and (select schedule_code from inventory.item where brand_name = 'Crocin') = 'H'
  and (select units_per_pack from inventory.item_pack p join inventory.item i on i.id = p.item_id where i.brand_name = 'Crocin') = 10
  and (select rate_bp from inventory.gst_rate where tenant_id = '11111111-1111-4111-8111-111111111111' and rate_bp = 1200) = 1200,
  'the first drug is ITM-0001 with schedule H, a strip of 10, and GST in basis points');

select tests.throws_ok(
  $$select inventory.create_item(
      '11111111-1111-4111-8111-111111111111',
      '{"itemKind":"consumable","brandName":"Gauze","manufacturerName":"Acme","scheduleCode":"H","hsnCode":"3005","gstRateBp":1200,"baseUomCode":"PC"}'::jsonb)$$,
  '22023',
  'a consumable cannot carry a drug schedule');

select inventory.create_store(
  '11111111-1111-4111-8111-111111111111',
  jsonb_build_object(
    'branchId', 'a1111111-0000-4000-8000-000000000001',
    'name', 'Main store',
    'storeKind', 'main'));

select tests.throws_ok(
  $$select inventory.create_store(
      '11111111-1111-4111-8111-111111111111',
      '{"branchId":"a1111111-0000-4000-8000-000000000001","name":"Pharmacy","storeKind":"op_pharmacy"}'::jsonb)$$,
  '23514',
  'a pharmacy without a current licence is refused');

select inventory.create_store(
  '11111111-1111-4111-8111-111111111111',
  jsonb_build_object(
    'branchId', 'a1111111-0000-4000-8000-000000000001',
    'name', 'Pharmacy',
    'storeKind', 'op_pharmacy',
    'drugLicenceNo', 'DL-1',
    'licenceValidTo', (current_date + 365)::text));

select tests.ok(
  (select code from inventory.store where name = 'Main store') = 'STR-0001'
  and (select code from inventory.store where name = 'Pharmacy') = 'STR-0002',
  'store codes are allocated and unique for the hospital');

select inventory.post_opening_stock(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  jsonb_build_object(
    'storeId', (select id from inventory.store where name = 'Pharmacy'),
    'lines', jsonb_build_array(
      jsonb_build_object(
        'itemId', (select id from inventory.item where brand_name = 'Crocin'),
        'batchNo', 'B1',
        'expiryDate', (current_date + 30)::text,
        'mrpPaise', 2500,
        'purchaseRatePaise', 1250,
        'qtyBase', 10),
      jsonb_build_object(
        'itemId', (select id from inventory.item where brand_name = 'Crocin'),
        'batchNo', 'B2',
        'expiryDate', (current_date + 400)::text,
        'mrpPaise', 2500,
        'purchaseRatePaise', 1100,
        'qtyBase', 20),
      jsonb_build_object(
        'itemId', (select id from inventory.item where brand_name = 'Crocin'),
        'batchNo', 'OLD',
        'expiryDate', (current_date - 1)::text,
        'mrpPaise', 2000,
        'purchaseRatePaise', 900,
        'qtyBase', 4))));

select tests.ok(
  (select doc_no from inventory.opening_stock) = 'OPN-0001'
  and (select approver_id from inventory.approval_request) = '0a000000-0000-4000-8000-000000000001'
  and (select sum(on_hand_base) from inventory.stock_balance_cache) = 34
  and (
    select (row ->> 'purchaseRatePaise')::bigint
    from jsonb_array_elements(inventory.stock_on_hand(
      '11111111-1111-4111-8111-111111111111',
      (select id from inventory.store where name = 'Pharmacy'),
      null)) row
    where row ->> 'batchNo' = 'B1'
  ) = 1250,
  'opening stock posts OPN-0001, records the signed-in approver, and keeps purchase rate on the ledger');

select inventory.post_opening_stock(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  jsonb_build_object(
    'storeId', (select id from inventory.store where name = 'Pharmacy'),
    'lines', jsonb_build_array(jsonb_build_object(
      'itemId', (select id from inventory.item where brand_name = 'Crocin'),
      'batchNo', 'B9', 'expiryDate', (current_date + 10)::text,
      'mrpPaise', 1, 'purchaseRatePaise', 1, 'qtyBase', 99))));

select tests.ok(
  (select count(*) from inventory.opening_stock) = 1
  and (select sum(on_hand_base) from inventory.stock_balance_cache) = 34,
  'replaying the idempotency key does not post a second document');

select tests.throws_ok(
  $$select inventory.post_opening_stock(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
      jsonb_build_object(
        'storeId', (select id from inventory.store where name = 'Pharmacy'),
        'lines', jsonb_build_array(jsonb_build_object(
          'itemId', (select id from inventory.item where brand_name = 'Crocin'),
          'batchNo', 'B1',
          'expiryDate', (current_date + 30)::text,
          'mrpPaise', 9999,
          'purchaseRatePaise', 1,
          'qtyBase', 1))))$$,
  '22023',
  'an existing batch keeps its MRP');

select tests.ok(
  (select inventory.fefo_pick_v1(
      '11111111-1111-4111-8111-111111111111',
      (select id from inventory.store where name = 'Pharmacy'),
      (select id from inventory.item where brand_name = 'Crocin'),
      15) ->> 'pickedBase')::bigint = 15
  and (select inventory.fefo_pick_v1(
      '11111111-1111-4111-8111-111111111111',
      (select id from inventory.store where name = 'Pharmacy'),
      (select id from inventory.item where brand_name = 'Crocin'),
      15) -> 'batches' -> 0 ->> 'batchNo') = 'B1'
  and (select inventory.fefo_pick_v1(
      '11111111-1111-4111-8111-111111111111',
      (select id from inventory.store where name = 'Pharmacy'),
      (select id from inventory.item where brand_name = 'Crocin'),
      15) -> 'batches' -> 1 ->> 'pickBase')::bigint = 5
  and not exists (
    select 1
    from jsonb_array_elements(inventory.fefo_pick_v1(
      '11111111-1111-4111-8111-111111111111',
      (select id from inventory.store where name = 'Pharmacy'),
      (select id from inventory.item where brand_name = 'Crocin'),
      null) -> 'batches') b
    where b ->> 'batchNo' = 'OLD'),
  'FEFO takes the earliest unexpired batch and skips expired stock');

select tests.ok(
  (select jsonb_object_agg(row ->> 'batchNo', row ->> 'expiryState')
   from jsonb_array_elements(inventory.stock_on_hand(
     '11111111-1111-4111-8111-111111111111', null, null)) row)
  = jsonb_build_object('OLD', 'expired', 'B1', 'soon', 'B2', 'ok'),
  'stock on hand marks expired, soon, and in-date batches');

select inventory.rebuild_stock_balance('11111111-1111-4111-8111-111111111111');
select tests.ok(
  (select sum(on_hand_base) from inventory.stock_balance_cache) = 34,
  'rebuilding the cache from the ledger restores the same on-hand quantity');

select tests.throws_ok(
  $$update inventory.stock_ledger set qty_delta_base = qty_delta_base + 1$$,
  'P0001',
  'the ledger rejects update');
select tests.throws_ok(
  $$delete from inventory.stock_ledger$$,
  'P0001',
  'the ledger rejects delete');
select tests.throws_ok(
  $$update inventory.batch set mrp_paise = 1$$,
  'P0001',
  'a batch rejects update');
select tests.throws_ok(
  $$insert into inventory.stock_balance_cache (store_id, batch_id, tenant_id, on_hand_base, reserved_base)
    select store_id, batch_id, tenant_id, 1, 0 from inventory.stock_balance_cache limit 1$$,
  'P0001',
  'the balance cache rejects a write that did not come from the ledger');

select tests.throws_ok(
  $$insert into inventory.stock_ledger (
      tenant_id, store_id, batch_id, qty_delta_base, movement, unit_cost_paise, source_type, source_id)
    select tenant_id, store_id, batch_id, -100, 'dispense', 0, 'test', gen_random_uuid()
    from inventory.stock_balance_cache
    order by on_hand_base
    limit 1$$,
  'P0001',
  'a movement that would go negative is refused');

set local session authorization hms_inventory_login;
set local role hms_svc_inventory;
select tests.throws_ok(
  $$update inventory.stock_ledger set unit_cost_paise = 0$$,
  '42501',
  'the inventory login cannot update the ledger');
reset role;
reset session authorization;

select tests.as_superuser();
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
set local session authorization hms_inventory_login;
set local role hms_svc_inventory;
select tests.throws_ok(
  $$select inventory.create_item(
      '11111111-1111-4111-8111-111111111111',
      '{"itemKind":"consumable","brandName":"Gauze","manufacturerName":"Acme","hsnCode":"3005","gstRateBp":500,"baseUomCode":"PC"}'::jsonb)$$,
  '42501',
  'a receptionist cannot create an item');
select tests.throws_ok(
  $$select inventory.post_opening_stock(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
      '{"storeId":"00000000-0000-4000-8000-000000000099","lines":[]}'::jsonb)$$,
  '42501',
  'opening stock requires the opening and approve permissions');
reset role;
reset session authorization;

rollback;
