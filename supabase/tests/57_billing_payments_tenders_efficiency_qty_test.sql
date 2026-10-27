-- #166 per-tender payments + applied amounts; #168 efficiency <= 100%; #167 whole quantities.
-- Migration 20261027180000.
begin;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doctor uuid := 'c1111111-0000-4000-8000-000000000002';
  v_doc jsonb;
  v_bill uuid;
  v_acct uuid;
  v_total bigint;
  v_pay jsonb;
  v_adv jsonb;
  v_card jsonb;
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  v_acct := (v_doc ->> 'accountId')::uuid;

  -- #167
  begin
    perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT', 'quantity', 1.5, 'practitionerId', v_doctor));
    perform tests.ok(false, 'a fractional quantity on a consultation is rejected');
  exception when invalid_parameter_value then
    perform tests.ok(true, 'a fractional quantity on a consultation is rejected');
  end;
  v_doc := billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT', 'quantity', 2, 'practitionerId', v_doctor));
  perform tests.ok(jsonb_array_length(v_doc -> 'lines') = 1, 'a whole quantity is accepted');

  v_doc := billing.finalize_bill(v_tenant, v_bill);
  v_total := (v_doc ->> 'totalPaise')::bigint;

  -- #166: split payment of 300 then an advance of 1000 with only the rest applied.
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(
      jsonb_build_object('mode', 'upi', 'amountPaise', 20000),
      jsonb_build_object('mode', 'card', 'amountPaise', 10000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 30000))));
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total))));
  perform billing.apply_advance(v_tenant, v_bill, jsonb_build_object('amountPaise', v_total - 30000));
  v_doc := billing.bill_json(v_bill);
  select p into v_pay from jsonb_array_elements(v_doc -> 'payments') p where p ->> 'kind' = 'payment';
  select p into v_adv from jsonb_array_elements(v_doc -> 'payments') p where p ->> 'kind' = 'advance';
  perform tests.ok(v_pay ->> 'mode' = 'split' and jsonb_array_length(v_pay -> 'tenders') = 2,
    'a split receipt shows as split with each tender');
  perform tests.ok(exists (select 1 from jsonb_array_elements(v_pay -> 'tenders') t
    where t ->> 'mode' = 'card' and (t ->> 'amountPaise')::bigint = 10000), 'the card tender keeps its own amount');
  perform tests.ok((v_adv ->> 'appliedPaise')::bigint = v_total - 30000,
    'the advance shows only the amount applied to this bill');
  perform tests.ok((v_adv ->> 'advanceBalancePaise')::bigint = 30000, 'the advance reports its remaining balance');
  perform tests.ok((select sum((p ->> 'appliedPaise')::bigint) from jsonb_array_elements(v_doc -> 'payments') p) = v_total,
    'applied amounts add up to the bill total');

  -- #168
  v_card := billing.earnings_card(
    jsonb_build_object('gross', 100000, 'collected', 108600, 'collectedOnBills', 90000, 'advances', 18600,
      'refunds', 0, 'bills', 1, 'visits', 1, 'doctors', 1, 'base', 100000, 'discount', 0,
      'doctorRevenue', 100000, 'cgst', 0, 'sgst', 0, 'igst', 0),
    jsonb_build_object('gross', 0, 'collected', 0, 'refunds', 0, 'bills', 0),
    jsonb_build_object('gross', 0), jsonb_build_object('gross', 0), jsonb_build_object('gross', 0), 0);
  perform tests.ok((v_card ->> 'collectionEfficiencyPct')::numeric = 90.0,
    'collection efficiency counts bill payments, not advances');
  perform tests.ok((v_card ->> 'advancesPaise')::bigint = 18600, 'advances are reported separately');
  v_card := billing.earnings_card(
    jsonb_build_object('gross', 100000, 'collected', 120000, 'collectedOnBills', 120000, 'advances', 0,
      'refunds', 0, 'bills', 1, 'visits', 1, 'doctors', 1, 'base', 100000, 'discount', 0,
      'doctorRevenue', 100000, 'cgst', 0, 'sgst', 0, 'igst', 0),
    jsonb_build_object('gross', 0, 'collected', 0, 'refunds', 0, 'bills', 0),
    jsonb_build_object('gross', 0), jsonb_build_object('gross', 0), jsonb_build_object('gross', 0), 0);
  perform tests.ok((v_card ->> 'collectionEfficiencyPct')::numeric = 100.0, 'collection efficiency never exceeds 100%');
end
$$;

rollback;
