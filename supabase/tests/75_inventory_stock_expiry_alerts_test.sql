-- Pharmacy stock and expiry alerts (20261031210000). Synthetic Zz-QA data, relative dates; rolls back.
begin;

select tests.as_superuser();
select tests.ok(
  has_function_privilege('hms_svc_inventory', 'inventory.stock_alerts(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'inventory.stock_alerts(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'pharmacy.set_alert_settings(uuid, jsonb)', 'execute')
  and has_function_privilege('hms_svc_inventory', 'inventory.set_reorder_policy(uuid, uuid, uuid, jsonb)', 'execute'),
  'alerts and settings run only through the inventory service');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);

select inventory.create_item('11111111-1111-4111-8111-111111111111', jsonb_build_object(
  'itemKind', 'drug', 'brandName', 'Zz-QA Paracip 75', 'genericName', 'Zz-QA Paracetamol', 'strength', '500 mg',
  'dosageForm', 'tablet', 'manufacturerName', 'Zz-QA Pharma', 'scheduleCode', 'H', 'hsnCode', '30049099',
  'gstRateBp', 1200, 'baseUomCode', 'TAB'));
select inventory.create_store('11111111-1111-4111-8111-111111111111', jsonb_build_object(
  'branchId', 'a1111111-0000-4000-8000-000000000001', 'name', 'Zz-QA 75 Pharmacy', 'storeKind', 'op_pharmacy',
  'drugLicenceNo', 'ZZQA-DL-75', 'licenceValidTo', (inventory.branch_today('a1111111-0000-4000-8000-000000000001') + 365)::text));

create temp table ids on commit drop as
select (select id from inventory.item where brand_name = 'Zz-QA Paracip 75') as item,
       (select id from inventory.store where name = 'Zz-QA 75 Pharmacy') as store,
       inventory.branch_today('a1111111-0000-4000-8000-000000000001') as today;
grant select on ids to public;

select inventory.post_opening_stock('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa7501',
  jsonb_build_object('storeId', (select store from ids), 'lines', jsonb_build_array(
    jsonb_build_object('itemId', (select item from ids), 'batchNo', 'ZZ75-EXP', 'expiryDate', ((select today from ids) - 1)::text,
                       'mrpPaise', 200, 'purchaseRatePaise', 100, 'qtyBase', 50),
    jsonb_build_object('itemId', (select item from ids), 'batchNo', 'ZZ75-SOON', 'expiryDate', ((select today from ids) + 20)::text,
                       'mrpPaise', 200, 'purchaseRatePaise', 100, 'qtyBase', 6),
    jsonb_build_object('itemId', (select item from ids), 'batchNo', 'ZZ75-OK', 'expiryDate', ((select today from ids) + 200)::text,
                       'mrpPaise', 200, 'purchaseRatePaise', 100, 'qtyBase', 4))));

select tests.throws_ok(
  $$select inventory.set_reorder_policy('11111111-1111-4111-8111-111111111111', (select store from ids), (select item from ids), '{"reorderLevel": -1}')$$,
  '22023', 'a negative reorder level is refused');
select inventory.set_reorder_policy('11111111-1111-4111-8111-111111111111', (select store from ids), (select item from ids),
  '{"reorderLevel": 20, "reorderQty": 100}');

do $$
declare
  a jsonb := inventory.stock_alerts('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001');
  low jsonb := (select e from jsonb_array_elements(a -> 'lowStock') e where e ->> 'brandName' = 'Zz-QA Paracip 75');
begin
  perform tests.ok(low is not null and (low ->> 'onHandBase')::int = 10 and (low ->> 'reorderLevel')::int = 20
    and (low ->> 'reorderQty')::int = 100,
    'low stock counts only unexpired stock (10 < reorder level 20; the 50 expired do not count)');
  perform tests.ok(
    (select array_agg(e ->> 'batchNo' order by ord) from jsonb_array_elements(a -> 'expiry') with ordinality x(e, ord)
      where e ->> 'brandName' = 'Zz-QA Paracip 75') = array['ZZ75-EXP', 'ZZ75-SOON']
    and (select e ->> 'kind' from jsonb_array_elements(a -> 'expiry') e where e ->> 'batchNo' = 'ZZ75-EXP') = 'expired'
    and (select (e ->> 'daysLeft')::int from jsonb_array_elements(a -> 'expiry') e where e ->> 'batchNo' = 'ZZ75-SOON') = 20,
    'expired and near-expiry batches are listed earliest expiry first; the 200-day batch is not');
  perform tests.ok((a -> 'counts' ->> 'expired')::int >= 1 and (a ->> 'nearExpiryDays')::int = 90, 'default window is 90 days');
end;
$$;

-- Tenant setting: a 10-day window drops the 20-day batch from the alert list and from stock_on_hand 'soon'.
select tests.throws_ok(
  $$select pharmacy.set_alert_settings('11111111-1111-4111-8111-111111111111', '{"nearExpiryDays": 0}')$$,
  '22023', 'a zero-day window is refused');
select pharmacy.set_alert_settings('11111111-1111-4111-8111-111111111111', '{"nearExpiryDays": 10}');
select tests.ok(
  not exists (select 1 from jsonb_array_elements(inventory.stock_alerts('11111111-1111-4111-8111-111111111111') -> 'expiry') e
              where e ->> 'batchNo' = 'ZZ75-SOON')
  and (select e ->> 'expiryState' from jsonb_array_elements(
         inventory.stock_on_hand('11111111-1111-4111-8111-111111111111', (select store from ids), null)) e
       where e ->> 'batchNo' = 'ZZ75-SOON') = 'ok'
  and (pharmacy.get_settings('11111111-1111-4111-8111-111111111111') ->> 'rxValidityDays')::int = 30,
  'the tenant near-expiry window drives alerts and stock status; rx validity is untouched');

-- Expired stock is never picked (FEFO starts at the earliest unexpired batch).
select tests.ok(
  (select (e ->> 'batchNo') from jsonb_array_elements(
     inventory.fefo_pick_v1('11111111-1111-4111-8111-111111111111', (select store from ids), (select item from ids), 1) -> 'batches') e limit 1) = 'ZZ75-SOON',
  'FEFO skips the expired batch and picks the nearest-expiry good batch');

-- Isolation: the other hospital's admin sees none of it and cannot change this tenant's settings.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0b000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0b000000-0000-4000-8000-000000000001', true);
select tests.ok(
  not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'inventory.view'),
  'another tenant''s admin has no inventory.view here, so inventory.assert_permission refuses the alerts');
select tests.throws_ok(
  $$select pharmacy.set_alert_settings('11111111-1111-4111-8111-111111111111', '{"nearExpiryDays": 30}')$$,
  '42501', 'another tenant cannot change the window');
select tests.ok(
  jsonb_array_length(inventory.stock_alerts('22222222-2222-4222-8222-222222222222') -> 'expiry') = 0,
  'own tenant alerts never include the other hospital''s batches');

rollback;
