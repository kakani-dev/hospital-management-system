-- #269: a refund credit note totals exactly the refund (no rupee rounding of the note itself).
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
  v_tax uuid; v_item uuid; v_odd uuid; v_list uuid;
  v_doc jsonb; v_bill uuid; v_acct uuid; v_pay uuid; v_note uuid; v_total bigint;
begin
  perform tests.billing_as(v_admin);
  perform billing.ensure_defaults(v_tenant);
  perform billing.set_branch_profile(v_tenant, v_main, jsonb_build_object('gstin', '36AABCU9603R1ZM', 'legalName', 'Alpha Hospital'));
  perform tests.as_superuser();
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'RX18', '998312', false, 1800, date '2017-07-01') returning id into v_tax;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'RXPROC', 'Exact note procedure', 'procedure', v_tax) returning id into v_item;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'RXODD', 'Exact note odd price', 'procedure', v_tax) returning id into v_odd;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  -- 10000 + 18% = 11800 (no rounding); 10042 + 1808 tax = 11850, which the bill rounds to 11900.
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, date '2017-07-01'), (v_tenant, v_list, v_odd, 10042, date '2017-07-01');

  perform tests.billing_as(v_admin);
  -- 1. Partial refunds on a round bill: each note equals its refund.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_bill := (v_doc ->> 'id')::uuid; v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform billing.finalize_bill(v_tenant, v_bill);
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 11800)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 11800))));
  v_pay := (v_doc ->> 'id')::uuid;

  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 1);
  perform tests.ok((select total_paise from billing.bill_totals_v1 where bill_id = v_note) = -1,
    'a 1 paisa refund gives a -1 paisa note, not 0.00');
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 6666);
  perform tests.ok((select total_paise from billing.bill_totals_v1 where bill_id = v_note) = -6666,
    'a 66.66 refund gives a -66.66 note, not -67.00');
  perform tests.ok((select round_off_paise from billing.bill_totals_v1 where bill_id = v_note) = 0,
    'a partial refund note has no round-off');
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 5133);
  perform tests.ok((select total_paise from billing.bill_totals_v1 where bill_id = v_note) = -5133,
    'the last partial refund note equals the refund');
  perform tests.ok((select sum(t.total_paise) from billing.bill_totals_v1 t join billing.bill b on b.id = t.bill_id
                    where b.reverses_bill_id = v_bill) = -11800, 'the notes together equal the bill total');

  -- 2. Full refund of a bill rounded down: the note equals the amount paid, the gap is its round-off.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_bill := (v_doc ->> 'id')::uuid; v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_odd));
  perform billing.finalize_bill(v_tenant, v_bill);
  select total_paise into v_total from billing.bill_totals_v1 where bill_id = v_bill;
  perform tests.ok(v_total % 100 = 0 and (select round_off_paise from billing.bill_totals_v1 where bill_id = v_bill) <> 0,
    'the test bill itself is rounded to the rupee (unchanged)');
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_total)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', v_total))));
  v_pay := (v_doc ->> 'id')::uuid;
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, v_total);
  perform tests.ok((select total_paise from billing.bill_totals_v1 where bill_id = v_note) = -v_total,
    'a full refund note equals the amount paid');
  perform tests.ok((select abs(round_off_paise) from billing.bill_totals_v1 where bill_id = v_note) between 1 and 99,
    'the rounding gap sits in the note''s round-off');

  -- 3. Override only on credit notes, within one rupee.
  perform tests.throws_ok(format('update billing.bill set round_off_override_paise = 5 where id = %L', v_bill),
    '55000', 'a finalized bill cannot take an override');
  perform tests.as_superuser();
  perform tests.throws_ok(format(
    'insert into billing.bill (tenant_id, account_id, bill_kind, round_off_override_paise) values (%L, %L, %L, 5)',
    v_tenant, v_acct, 'final'), '23514', 'only a credit note may carry a fixed round-off');
end
$do$;

select tests.as_superuser();
rollback;
