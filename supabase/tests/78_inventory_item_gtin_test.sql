-- Pharmacy barcode scanning: per-tenant GTIN link (20261101001000). Synthetic Zz-QA data; rolls back.
begin;

select tests.as_superuser();
select tests.ok(
  has_function_privilege('hms_svc_inventory', 'inventory.resolve_gtin(uuid, text)', 'execute')
  and has_function_privilege('hms_svc_inventory', 'inventory.link_gtin(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'inventory.link_gtin(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'inventory.resolve_gtin(uuid, text)', 'execute')
  and not has_table_privilege('authenticated', 'inventory.item_gtin', 'select')
  and (select relrowsecurity from pg_class where oid = 'inventory.item_gtin'::regclass),
  'GTIN links run only through the inventory service and the table has RLS');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);

select inventory.create_item('11111111-1111-4111-8111-111111111111', jsonb_build_object(
  'itemKind', 'drug', 'brandName', 'Zz-QA Scanol 78', 'genericName', 'Zz-QA Scanolide', 'strength', '250 mg',
  'dosageForm', 'tablet', 'manufacturerName', 'Zz-QA Pharma', 'scheduleCode', 'H', 'hsnCode', '30049099',
  'gstRateBp', 1200, 'baseUomCode', 'TAB'));
select inventory.create_item('11111111-1111-4111-8111-111111111111', jsonb_build_object(
  'itemKind', 'drug', 'brandName', 'Zz-QA Other 78', 'genericName', 'Zz-QA Otherine', 'strength', '5 mg',
  'dosageForm', 'tablet', 'manufacturerName', 'Zz-QA Pharma', 'scheduleCode', 'H', 'hsnCode', '30049099',
  'gstRateBp', 1200, 'baseUomCode', 'TAB'));

create temp table ids on commit drop as
select (select id from inventory.item where brand_name = 'Zz-QA Scanol 78') as item,
       (select id from inventory.item where brand_name = 'Zz-QA Other 78') as other;
grant select on ids to public;

select tests.ok(
  inventory.resolve_gtin('11111111-1111-4111-8111-111111111111', '08901234567890') -> 'item' = 'null'::jsonb,
  'an unknown GTIN resolves to no item');
select tests.throws_ok(
  $$select inventory.resolve_gtin('11111111-1111-4111-8111-111111111111', '8901234')$$,
  '22023', 'a GTIN that is not 14 digits is refused');
select tests.ok(
  inventory.link_gtin('11111111-1111-4111-8111-111111111111',
    jsonb_build_object('gtin', '08901234567890', 'itemId', (select item from ids))) -> 'item' ->> 'brandName' = 'Zz-QA Scanol 78',
  'linking returns the catalogue item');
select tests.ok(
  inventory.link_gtin('11111111-1111-4111-8111-111111111111',
    jsonb_build_object('gtin', '08901234567890', 'itemId', (select item from ids))) -> 'item' ->> 'brandName' = 'Zz-QA Scanol 78'
  and (select count(*) from inventory.item_gtin where gtin = '08901234567890') = 1,
  'linking the same item again is a no-op');
select tests.throws_ok(
  $$select inventory.link_gtin('11111111-1111-4111-8111-111111111111',
      jsonb_build_object('gtin', '08901234567890', 'itemId', (select other from ids)))$$,
  '23505', 'a GTIN cannot be re-pointed at a different item');
select tests.throws_ok(
  $$select inventory.link_gtin('11111111-1111-4111-8111-111111111111',
      jsonb_build_object('gtin', '08901234567890', 'itemId', 'not-a-uuid'))$$,
  '22023', 'a bad item id is refused');

-- Isolation: the other hospital sees nothing, cannot link into this hospital, and cannot link this hospital's item.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0b000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0b000000-0000-4000-8000-000000000001', true);
-- The owner session bypasses inventory.assert_permission (inventory.bypass_acl), so check the
-- permission it relies on directly: resolve needs inventory.view, link needs inventory.catalog.
select tests.ok(
  not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'inventory.view')
  and not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'inventory.catalog'),
  'another tenant has no permission to look up or link this hospital''s GTINs');
select tests.ok(
  inventory.resolve_gtin('22222222-2222-4222-8222-222222222222', '08901234567890') -> 'item' = 'null'::jsonb,
  'the same GTIN is unlinked in the other hospital');
select tests.throws_ok(
  $$select inventory.link_gtin('22222222-2222-4222-8222-222222222222',
      jsonb_build_object('gtin', '08901234567890', 'itemId', (select item from ids)))$$,
  'P0002', 'a hospital cannot link another hospital''s item');

rollback;
