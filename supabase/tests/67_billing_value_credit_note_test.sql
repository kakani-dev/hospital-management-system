-- #261: a refund of a finalized bill issues a value-based GST credit note (CGST s.34):
-- whole-unit services, small refunds, mixed tax rates, no over-credit.
begin;

create or replace function tests.billing_as(p_user uuid)
returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  execute 'set local role hms_svc_billing';
end
$fn$;

do $do$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_main uuid := 'a1111111-0000-4000-8000-000000000001';
  v_admin uuid := '0a000000-0000-4000-8000-000000000001';
  v_asha uuid := 'aa000000-0000-4000-8000-000000000001';
  v_tax uuid; v_exempt uuid; v_item uuid; v_free uuid; v_list uuid;
  v_doc jsonb; v_bill uuid; v_acct uuid; v_pay uuid; v_note uuid; v_line uuid;
  v_draft uuid; v_draft_pay uuid;
begin
  perform tests.billing_as(v_admin);
  perform billing.ensure_defaults(v_tenant);
  perform billing.set_branch_profile(v_tenant, v_main, jsonb_build_object('gstin', '36AABCU9603R1ZM', 'legalName', 'Alpha Hospital'));
  perform tests.as_superuser();
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'VC18', '998311', false, 1800, date '2017-07-01') returning id into v_tax;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'VC00', '999311', true, 0, date '2017-07-01') returning id into v_exempt;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'VCPROC', 'Value credit procedure', 'procedure', v_tax) returning id into v_item;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'VCCONS', 'Value credit consult', 'consultation', v_exempt) returning id into v_free;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, date '2017-07-01'), (v_tenant, v_list, v_free, 5000, date '2017-07-01');

  perform tests.billing_as(v_admin);
  -- Bill: 1 x procedure Rs 100 + 18% = 11800, 1 x exempt consult 5000. Total 16800, paid in full.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_bill := (v_doc ->> 'id')::uuid; v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_free));
  perform billing.finalize_bill(v_tenant, v_bill);
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 16800)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 16800))));
  v_pay := (v_doc ->> 'id')::uuid;

  -- 1. Half refund of a whole-unit bill works (was: "quantity must be a whole number").
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 8400);
  perform tests.ok(v_note is not null, 'a partial refund of whole-unit services issues a credit note');
  perform tests.ok(billing.bill_gross(v_note) = -8400, 'the credit note equals the refund (-8400)');
  perform tests.ok(not exists (select 1 from billing.bill_line where bill_id = v_note and quantity <> trunc(quantity)),
    'no fractional quantity on the credit note');
  perform tests.ok((select bool_and(credit_basis = 'value' and quantity = -1) from billing.bill_line where bill_id = v_note),
    'credit note lines are value-based');
  perform tests.ok((select status from billing.bill where id = v_note) = 'finalized', 'the credit note is finalized');
  -- GST reversal is proportional: the taxed line gets 11800/16800 of 8400 = 5900 -> taxable 5000, GST 900.
  perform tests.ok((select sum(billing.line_tax(quantity, unit_price_paise, tax_rate_bp)) from billing.bill_line where bill_id = v_note) = -900,
    'GST reversed at the line rate (-900 on the 18% line)');
  perform tests.ok((select unit_price_paise from billing.bill_line where bill_id = v_note and tax_rate_bp = 0) = 2500,
    'the exempt line gets its share with no GST (2500)');

  -- 2. A one-paisa refund still issues a credit note (was: rounded to quantity 0, none issued).
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 1);
  perform tests.ok(v_note is not null and billing.bill_gross(v_note) = -1, 'a 1 paisa refund issues a 1 paisa credit note');

  -- 3. A quantity credit cannot exceed what is left after value credits.
  select id into v_line from billing.bill_line where bill_id = v_bill and service_item_id = v_item;
  perform tests.throws_ok(
    format('select billing.create_credit_note(%L::uuid, %L::uuid, %L::jsonb)', v_tenant, v_bill,
      jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 1)))),
    '22023', 'a full-unit credit after a half value credit is refused (no over-credit)');

  -- 4. Refunding the rest credits exactly what is left; nothing remains creditable.
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 8399);
  perform tests.ok(billing.bill_gross(v_note) = -8399, 'the remaining refund credits exactly the remainder');
  perform tests.ok((select sum(billing.line_creditable_gross(id)) from billing.bill_line where bill_id = v_bill) = 0,
    'the bill is fully credited');
  perform tests.ok(-(select sum(billing.bill_gross(id)) from billing.bill where reverses_bill_id = v_bill and bill_kind = 'credit_note') = 16800,
    'all credit notes together equal the bill total');
  perform tests.ok(billing.credit_note_for_refund(v_tenant, v_pay, 100) is null, 'nothing more is credited once the bill is fully credited');

  -- 5. Draft bill: a refund clearing every allocation still finalizes and credits it in full.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_draft := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_draft, jsonb_build_object('serviceItemId', v_item, 'quantity', 2));
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', (v_doc ->> 'accountId')::uuid, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 23600)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_draft, 'amountPaise', 23600))));
  v_draft_pay := (v_doc ->> 'id')::uuid;
  perform tests.ok(billing.credit_note_for_refund(v_tenant, v_draft_pay, 1000) is null, 'a partial refund of a draft issues no credit note');
  v_note := billing.credit_note_for_refund(v_tenant, v_draft_pay, 23600);
  perform tests.ok(billing.bill_gross(v_note) = -23600, 'a full refund of a draft credits the whole bill');
end
$do$;

select tests.as_superuser();
rollback;
