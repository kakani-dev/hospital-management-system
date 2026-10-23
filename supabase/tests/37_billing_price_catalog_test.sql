-- Price catalog: list, precedence, overlap preview, copy onto a branch, desk cannot edit.
begin;

select tests.ok(
  has_function_privilege('hms_svc_billing', 'billing.import_prices(uuid, jsonb)', 'execute')
  and has_function_privilege('hms_svc_billing', 'billing.copy_price_list(uuid, jsonb)', 'execute')
  and has_function_privilege('hms_svc_billing', 'billing.list_service_items(uuid, text, boolean)', 'execute')
  and not has_function_privilege('anon', 'billing.import_prices(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'billing.list_prices(uuid, uuid)', 'execute'),
  'catalog reads and price import are executable by the billing role only');

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_prac uuid := 'c1111111-0000-4000-8000-000000000099';
  v_doc jsonb;
  v_item uuid;
  v_list uuid;
  v_price jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.list_service_items(v_tenant, null, false);
  perform tests.ok(
    v_doc @> '[{"code":"CONSULT","sacHsnCode":"9993","isExempt":true}]'::jsonb,
    'the catalog lists the consultation with SAC 9993');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', true, 'rows', jsonb_build_array(
    jsonb_build_object('clientIndex', 0, 'code', 'NOT-CONSULT', 'name', 'OP consultation', 'category', 'consultation', 'unitPricePaise', 60000, 'effectiveFrom', '2026-04-01'))));
  perform tests.ok(
    v_doc -> 'rows' -> 0 ->> 'status' = 'price_overlap'
    and v_doc -> 'rows' -> 0 ->> 'code' = 'CONSULT'
    and v_doc -> 'rows' -> 0 ->> 'item' = 'existing',
    'a preview matches the consultation by name and category and ignores a code column');
  perform tests.ok(
    (select count(*) from billing.price_list_item pli
      join billing.service_item si on si.id = pli.service_item_id
      where si.code = 'CONSULT' and si.tenant_id = v_tenant and not pli.is_deleted) = 1,
    'a dry run does not write a price');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', true, 'rows', jsonb_build_array(
    jsonb_build_object('clientIndex', 0, 'code', 'DRESS', 'name', 'Wound dressing', 'category', 'procedure', 'sac', '9993', 'unitPricePaise', 15000, 'effectiveFrom', '2017-07-01'),
    jsonb_build_object('clientIndex', 1, 'code', 'DRESS', 'name', 'Wound dressing', 'category', 'procedure', 'unitPricePaise', 18000, 'effectiveFrom', '2018-01-01'))));
  perform tests.ok(v_doc -> 'rows' -> 0 ->> 'status' = 'ready' and v_doc -> 'rows' -> 0 ->> 'item' = 'create', 'a new dressing is ready to import');
  perform tests.ok(v_doc -> 'rows' -> 1 ->> 'status' = 'price_overlap', 'a later row in the same file that overlaps is marked');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', false, 'rows', jsonb_build_array(
    jsonb_build_object('clientIndex', 0, 'code', 'DRESS', 'name', 'Wound dressing', 'category', 'procedure', 'sac', '9993', 'unitPricePaise', 15000, 'effectiveFrom', '2017-07-01'))));
  perform tests.ok(v_doc -> 'rows' -> 0 ->> 'status' = 'ready', 'applying the preview writes the dressing');
  perform tests.ok(
    (select code from billing.service_item
      where tenant_id = v_tenant and name = 'Wound dressing' and not is_deleted) = 'PROC-0001',
    'the imported code column is ignored and the server assigns PROC-0001');
  perform tests.ok(
    (billing.list_service_items(v_tenant, 'dress', false) -> 0 ->> 'hospitalPricePaise')::bigint = 15000,
    'the hospital rate is stored in paise and listed with the service');

  v_item := (billing.upsert_service_item(v_tenant, jsonb_build_object(
    'name', 'Precedence probe', 'category', 'procedure')) ->> 'id')::uuid;
  perform billing.add_price(v_tenant, jsonb_build_object(
    'serviceItemId', v_item, 'unitPricePaise', 10000, 'effectiveFrom', '2026-01-01'));
  perform billing.add_price(v_tenant, jsonb_build_object(
    'serviceItemId', v_item, 'branchId', v_branch, 'unitPricePaise', 20000, 'effectiveFrom', '2026-01-01'));
  perform billing.add_price(v_tenant, jsonb_build_object(
    'serviceItemId', v_item, 'practitionerId', v_prac, 'unitPricePaise', 30000, 'effectiveFrom', '2026-01-01'));

  v_price := billing.resolve_price(v_tenant, v_branch, v_item, v_prac, date '2026-06-01');
  perform tests.ok((v_price ->> 'unitPricePaise')::bigint = 30000, 'a practitioner rate beats the branch rate');
  v_price := billing.resolve_price(v_tenant, v_branch, v_item, null, date '2026-06-01');
  perform tests.ok((v_price ->> 'unitPricePaise')::bigint = 20000, 'a branch rate beats the hospital rate');
  v_price := billing.resolve_price(v_tenant, v_branch, v_item, 'c1111111-0000-4000-8000-000000000098', date '2026-06-01');
  perform tests.ok((v_price ->> 'unitPricePaise')::bigint = 20000, 'another practitioner falls through to the branch rate');

  begin
    perform billing.add_price(v_tenant, jsonb_build_object(
      'serviceItemId', v_item, 'branchId', v_branch, 'unitPricePaise', 21000, 'effectiveFrom', '2026-02-01'));
    perform tests.ok(false, 'an overlapping branch rate must be rejected');
  exception when sqlstate '23P01' then
    perform tests.ok(true, 'an overlapping branch rate is rejected');
  end;

  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  v_doc := billing.copy_price_list(v_tenant, jsonb_build_object(
    'sourcePriceListId', v_list, 'branchId', v_branch, 'effectiveFrom', '2026-04-01', 'dryRun', true));
  perform tests.ok((v_doc ->> 'copied')::int >= 1 and jsonb_array_length(v_doc -> 'conflicts') >= 1,
    'copy preview counts new branch rates and skips ones that already overlap');
  perform tests.ok((v_doc -> 'conflicts') @> '[{"reason":"price_overlap"}]'::jsonb, 'a copy conflict is price_overlap');
  v_doc := billing.copy_price_list(v_tenant, jsonb_build_object(
    'sourcePriceListId', v_list, 'branchId', v_branch, 'effectiveFrom', '2026-04-01', 'dryRun', false));
  perform tests.ok((v_doc ->> 'copied')::int >= 1 and v_doc ->> 'priceListId' is not null, 'copy writes the branch rates that do not overlap');
end
$$;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_doc jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.list_service_items(v_tenant, 'dress', false);
  perform tests.ok(
    v_doc -> 0 ->> 'code' = 'PROC-0001' and v_doc -> 0 ->> 'name' = 'Wound dressing',
    'a receptionist can search the catalog to add a bill line');
  perform tests.throws_ok(
    'select billing.list_prices(''11111111-1111-4111-8111-111111111111'', null)',
    '42501',
    'a receptionist cannot list price rows');
  perform tests.throws_ok(
    'select billing.import_prices(''11111111-1111-4111-8111-111111111111'', ''{"rows":[]}''::jsonb)',
    '42501',
    'a receptionist cannot import prices');
end
$$;

rollback;
