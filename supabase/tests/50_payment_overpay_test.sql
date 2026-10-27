-- #143 (PAY-005, PAY-006): overpaying or paying a bill with nothing due fails inside the
-- record_payment call with 22023 (400), not at COMMIT (which the API turned into a 500).
-- Synthetic data only.
begin;

create function pg_temp.pay_error(p_tenant uuid, p_body jsonb)
returns text language plpgsql as $f$
begin
  perform billing.record_payment(p_tenant, gen_random_uuid(), p_body);
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$f$;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_account uuid;
  v_total bigint;
  v_err text;
  v_idem uuid := gen_random_uuid();
  v_pay jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  v_account := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  v_doc := billing.finalize_bill(v_tenant, v_bill);
  v_total := (v_doc ->> 'totalPaise')::bigint;
  perform tests.ok(v_total > 100, 'the synthetic bill has an amount due');

  -- PAY-005: overpay
  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total + 10000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', v_total + 10000))));
  perform tests.ok(v_err like '22023: allocations exceed the bill total: ₹% is due',
    'PAY-005: an overpay is a 22023 inside the call: ' || v_err);

  -- two allocations to the same bill that together overpay
  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total + 2)),
    'allocations', jsonb_build_array(
      jsonb_build_object('billId', v_bill, 'amountPaise', v_total),
      jsonb_build_object('billId', v_bill, 'amountPaise', 2))));
  perform tests.ok(v_err like '22023: allocations exceed the bill total%', 'split allocations are summed per bill: ' || v_err);

  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', 'nope', 'amountPaise', 100))));
  perform tests.ok(v_err = '22023: each allocation needs the billId of a bill on this account', 'a malformed billId: ' || v_err);
  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', gen_random_uuid(), 'amountPaise', 100))));
  perform tests.ok(v_err = '22023: allocation bill not found for this patient', 'an unknown bill: ' || v_err);
  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 'x'))));
  perform tests.ok(v_err = '22023: an allocation must be a positive amount', 'a non-numeric amount: ' || v_err);

  -- exact payment still works, and its replay returns the same receipt
  v_pay := billing.record_payment(v_tenant, v_idem, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', v_total))));
  perform tests.ok((select due_paise from billing.bill_balance_v1 where bill_id = v_bill) = 0, 'paying exactly the due works');
  perform tests.ok(billing.record_payment(v_tenant, v_idem, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', v_total)))) ->> 'id' = v_pay ->> 'id',
    'a replay of the same key still returns the original receipt');

  -- PAY-006: nothing due
  v_err := pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 100))));
  perform tests.ok(v_err = '22023: nothing is due on this bill', 'PAY-006: paying a fully paid bill: ' || v_err);

  -- an advance (no allocation) is unaffected
  perform tests.ok(pg_temp.pay_error(v_tenant, jsonb_build_object('accountId', v_account, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100)))) = 'no error',
    'an advance with no allocation still records');
end
$$;

rollback;
