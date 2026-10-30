-- #109: a taxed bill cannot be finalized without a known supplier state and place of supply.
begin;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_tax uuid;
  v_exempt uuid;
  v_item uuid;
  v_free uuid;
  v_list uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);
  execute 'reset role';
  update billing.branch_profile set gstin = null where tenant_id = v_tenant and branch_id = v_branch;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'T18P', '998311', false, 1800, date '2017-07-01') returning id into v_tax;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'EXP', '999311', true, 0, date '2017-07-01') returning id into v_exempt;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'POS18', 'Taxable procedure', 'procedure', v_tax) returning id into v_item;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'POS0', 'Exempt consult', 'procedure', v_exempt) returning id into v_free;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, date '2017-07-01'), (v_tenant, v_list, v_free, 5000, date '2017-07-01');
  execute 'set local role hms_svc_billing';

  -- missing: no branch GSTIN, no place of supply, taxed line
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  begin
    perform billing.finalize_bill(v_tenant, v_bill);
    perform tests.ok(false, 'a taxed bill with no supplier state must not finalize');
  exception when sqlstate '22023' then
    perform tests.ok(sqlerrm like 'place of supply is required%', 'a taxed bill with no GSTIN or place of supply is refused (22023)');
  end;
  perform tests.ok((select status from billing.bill where id = v_bill) = 'draft', 'the refused bill stays a draft');

  -- an explicit place of supply alone is not enough: the supplier state is still unknown
  perform billing.set_place_of_supply(v_tenant, v_bill, '27');
  begin
    perform billing.finalize_bill(v_tenant, v_bill);
    perform tests.ok(false, 'place of supply without a supplier state must not finalize');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'a place of supply without a supplier GSTIN state is still refused');
  end;

  -- exempt-only bill without a GSTIN still finalizes
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  perform billing.add_line(v_tenant, (v_doc ->> 'id')::uuid, jsonb_build_object('serviceItemId', v_free));
  v_doc := billing.finalize_bill(v_tenant, (v_doc ->> 'id')::uuid);
  perform tests.ok(v_doc ->> 'status' = 'finalized', 'an untaxed bill without a GSTIN still finalizes');

  -- intra-state: GSTIN set, place of supply defaults to the branch state
  perform billing.set_branch_profile(v_tenant, v_branch, jsonb_build_object('gstin', '36AABCU9603R1ZM'));
  perform billing.set_place_of_supply(v_tenant, v_bill, '36');
  v_doc := billing.finalize_bill(v_tenant, v_bill);
  perform tests.ok(v_doc ->> 'status' = 'finalized' and (v_doc ->> 'cgstPaise')::bigint = 900
    and (v_doc ->> 'igstPaise')::bigint = 0, 'intra-state finalizes as CGST + SGST');

  -- inter-state
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform billing.set_place_of_supply(v_tenant, v_bill, '27');
  v_doc := billing.finalize_bill(v_tenant, v_bill);
  perform tests.ok((v_doc ->> 'igstPaise')::bigint = 1800 and (v_doc ->> 'cgstPaise')::bigint = 0,
    'inter-state finalizes as IGST');
end
$$;

rollback;
