-- Generated service codes and category tax defaults. A client code is rejected. Existing codes stay put.
begin;

select tests.ok(
  has_function_privilege('hms_svc_billing', 'billing.allocate_service_code(uuid, text, text)', 'execute')
  and has_function_privilege('hms_svc_billing', 'billing.list_category_defaults(uuid)', 'execute')
  and not has_function_privilege('anon', 'billing.allocate_service_code(uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'billing.list_category_defaults(uuid)', 'execute'),
  'code allocation and category defaults are executable by the billing role only');

select tests.ok(
  (select relrowsecurity from pg_class where oid = 'billing.service_code_seq'::regclass)
  and not has_table_privilege('hms_svc_billing', 'billing.service_code_seq', 'select')
  and not has_table_privilege('anon', 'billing.service_code_seq', 'select')
  and not has_table_privilege('authenticated', 'billing.service_code_seq', 'insert'),
  'the code counter is locked to the allocator');

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_doc jsonb;
  v_id uuid;
  v_next jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.list_category_defaults(v_tenant);
  perform tests.ok(
    v_doc @> '[{"category":"procedure","codePrefix":"PROC","sacHsnCode":"9993","rateBp":0,"isExempt":true}]'::jsonb,
    'a procedure defaults to exempt healthcare under SAC 9993');
  perform tests.ok(
    v_doc @> '[{"category":"other","codePrefix":"CERT","sacHsnCode":"9997","rateBp":1800,"isExempt":false}]'::jsonb,
    'a non-clinical category defaults to 18 percent under SAC 9997');

  v_doc := billing.upsert_service_item(v_tenant, jsonb_build_object('name', 'Dressing', 'category', 'procedure'));
  perform tests.ok(v_doc ->> 'code' = 'PROC-0001', 'the first generated code is PROC-0001');
  perform tests.ok(
    (select tc.is_exempt and tc.rate_bp = 0 and tc.sac_hsn_code = '9993'
     from billing.service_item si
     join billing.tax_code tc on tc.id = si.tax_code_id
     where si.id = (v_doc ->> 'id')::uuid),
    'a procedure with no tax uses the exempt default');

  v_doc := billing.upsert_service_item(v_tenant, jsonb_build_object('name', 'Fitness certificate', 'category', 'other'));
  perform tests.ok(v_doc ->> 'code' = 'CERT-0002', 'the next category continues the same sequence');
  perform tests.ok(
    (select (not tc.is_exempt) and tc.rate_bp = 1800 and tc.sac_hsn_code = '9997'
     from billing.service_item si
     join billing.tax_code tc on tc.id = si.tax_code_id
     where si.id = (v_doc ->> 'id')::uuid),
    'a certificate with no tax uses the 18 percent default');

  begin
    perform billing.upsert_service_item(v_tenant, jsonb_build_object(
      'code', 'LEGACY', 'name', 'Legacy dressing', 'category', 'procedure'));
    perform tests.ok(false, 'a supplied code must be rejected');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'a supplied code is rejected');
  end;
  perform tests.ok(
    not exists (select 1 from billing.service_item where tenant_id = v_tenant and code = 'LEGACY'),
    'a rejected code is not stored');

  begin
    perform billing.allocate_service_code(v_tenant, 'procedure', 'PROC-0009');
    perform tests.ok(false, 'allocate must not accept a typed code');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'allocate rejects a typed code and does not move the counter');
  end;

  select id into v_id from billing.service_item
  where tenant_id = v_tenant and code = 'CONSULT' and not is_deleted;
  v_doc := billing.upsert_service_item(v_tenant, jsonb_build_object('id', v_id, 'name', 'OP consultation renamed'));
  perform tests.ok(v_doc ->> 'code' = 'CONSULT', 'an existing code is not replaced');
  perform tests.ok(
    (select code from billing.service_item where id = v_id) = 'CONSULT',
    'CONSULT is still the stored code');

  begin
    perform billing.upsert_service_item(v_tenant, jsonb_build_object(
      'id', v_id, 'code', 'RENAME', 'name', 'OP consultation renamed again'));
    perform tests.ok(false, 'a code on update must be rejected');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'a code on update is rejected');
  end;
  perform tests.ok(
    (select code from billing.service_item where id = v_id) = 'CONSULT'
    and (select name from billing.service_item where id = v_id) = 'OP consultation renamed',
    'a rejected update leaves CONSULT and the previous name');

  v_next := billing.upsert_service_item(v_tenant, jsonb_build_object('name', 'After rejection', 'category', 'procedure'));
  perform tests.ok(v_next ->> 'code' = 'PROC-0003', 'a rejected code does not move the counter');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', true, 'rows', jsonb_build_array(
    jsonb_build_object('name', 'Suture', 'category', 'procedure', 'unitPricePaise', 25000, 'effectiveFrom', '2026-04-01'),
    jsonb_build_object('name', 'Suture', 'category', 'procedure', 'unitPricePaise', 26000, 'effectiveFrom', '2026-04-01'))));
  perform tests.ok(
    v_doc -> 'rows' -> 0 ->> 'status' = 'ready' and v_doc -> 'rows' -> 0 ->> 'item' = 'create'
    and v_doc -> 'rows' -> 0 ->> 'code' is null,
    'a dry run without a code is ready and does not assign one');
  perform tests.ok(v_doc -> 'rows' -> 1 ->> 'status' = 'price_overlap', 'two open prices for the same new service overlap in the file');
  perform tests.ok(
    not exists (select 1 from billing.service_item where tenant_id = v_tenant and name = 'Suture'),
    'a dry run does not write the service');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', false, 'rows', jsonb_build_array(
    jsonb_build_object('name', 'Suture', 'category', 'procedure', 'unitPricePaise', 25000, 'effectiveFrom', '2026-04-01'),
    jsonb_build_object('name', 'Fitness form', 'category', 'other', 'unitPricePaise', 20000, 'effectiveFrom', '2026-04-01'))));
  perform tests.ok(v_doc -> 'rows' -> 0 ->> 'code' ~ '^[A-Z]+-[0-9]{4}$', 'apply assigns a generated code');
  perform tests.ok(
    (select tc.is_exempt and tc.sac_hsn_code = '9993'
     from billing.service_item si
     join billing.tax_code tc on tc.id = si.tax_code_id
     where si.tenant_id = v_tenant and si.name = 'Suture'),
    'an imported procedure with no SAC uses the exempt default');
  perform tests.ok(
    (select tc.rate_bp = 1800 and tc.sac_hsn_code = '9997'
     from billing.service_item si
     join billing.tax_code tc on tc.id = si.tax_code_id
     where si.tenant_id = v_tenant and si.name = 'Fitness form'),
    'an imported certificate with no SAC uses the 18 percent default');
  perform tests.ok(
    (select count(*) from billing.service_item where tenant_id = v_tenant and name = 'Suture' and not is_deleted) = 1,
    'one generated item is written for the applied row');

  v_doc := billing.import_prices(v_tenant, jsonb_build_object('dryRun', true, 'rows', jsonb_build_array(
    jsonb_build_object('code', 'NOT-THE-CODE', 'name', 'Suture', 'category', 'procedure', 'unitPricePaise', 25000, 'effectiveFrom', '2026-04-01'),
    jsonb_build_object('code', 'CONSULT', 'unitPricePaise', 100, 'effectiveFrom', '2026-04-01'))));
  perform tests.ok(
    v_doc -> 'rows' -> 0 ->> 'item' = 'existing'
    and v_doc -> 'rows' -> 0 ->> 'status' = 'price_overlap'
    and v_doc -> 'rows' -> 0 ->> 'code' <> 'NOT-THE-CODE'
    and v_doc -> 'rows' -> 0 ->> 'code' ~ '^[A-Z]+-[0-9]{4}$',
    'import matches name and category and ignores a code column');
  perform tests.ok(
    v_doc -> 'rows' -> 1 ->> 'status' = 'error' and v_doc -> 'rows' -> 1 ->> 'detail' = 'name is required',
    'import requires a name when the code column is the only identifier');

  v_doc := billing.upsert_service_item(v_tenant, jsonb_build_object(
    'code', '   ', 'name', 'Blank code', 'category', 'lab'));
  perform tests.ok(v_doc ->> 'code' ~ '^LAB-', 'a blank code is treated as omitted and allocated');
end
$$;

do $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  execute 'set local role hms_svc_billing';
  perform tests.throws_ok(
    $q$select billing.allocate_service_code('11111111-1111-4111-8111-111111111111', 'procedure', null)$q$,
    '42501',
    'a receptionist cannot allocate a service code');
  perform tests.throws_ok(
    $q$select billing.list_category_defaults('11111111-1111-4111-8111-111111111111')$q$,
    '42501',
    'a receptionist cannot read category tax defaults');
end
$$;

rollback;
