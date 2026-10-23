-- Open bill: consultation is collected before the invoice number, later lines share that bill,
-- the drawer includes cash receipts and cash refunds, and money rows reject updates.
begin;

select tests.ok(
  not has_table_privilege('hms_svc_billing', 'billing.payment', 'UPDATE')
  and not has_table_privilege('hms_svc_billing', 'billing.payment_tender', 'UPDATE')
  and not has_table_privilege('hms_svc_billing', 'billing.allocation', 'UPDATE')
  and has_table_privilege('hms_svc_billing', 'billing.payment', 'INSERT')
  and has_table_privilege('hms_svc_billing', 'billing.payment', 'SELECT'),
  'payment, tender and allocation can be inserted and read, not updated');

create temporary table t_money (payment_id uuid, tender_id uuid, allocation_id uuid) on commit drop;
grant all on table t_money to hms_svc_billing;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_account uuid;
  v_line uuid;
  v_second uuid;
  v_item uuid;
  v_list uuid;
  v_session uuid;
  v_pay jsonb;
  v_pay2 jsonb;
  v_refund jsonb;
  v_hook jsonb;
  v_close jsonb;
  v_link jsonb;
  v_other uuid;
  v_receipt text;
  v_receipt2 text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.ensure_cashier_session(v_tenant, v_branch);
  v_session := (v_doc ->> 'id')::uuid;
  perform tests.ok(v_session is not null and (v_doc ->> 'opened')::boolean,
    'the cashier session opens on its own with no counter name to type');
  perform tests.ok((billing.ensure_cashier_session(v_tenant, v_branch) ->> 'id')::uuid = v_session
    and (billing.ensure_cashier_session(v_tenant, v_branch) ->> 'opened')::boolean = false,
    'a second call reuses the open session');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  v_account := (v_doc ->> 'accountId')::uuid;
  v_doc := billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  perform tests.ok(v_doc ->> 'status' = 'draft' and v_doc ->> 'billNo' is null
    and (v_doc ->> 'totalPaise')::bigint = 50000 and (v_doc -> 'lines' -> 0 ->> 'locked')::boolean = false,
    'check-in leaves an unnumbered draft with the consultation');

  begin
    perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
      'accountId', v_account, 'kind', 'payment',
      'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 50000)),
      'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 50000))));
    perform tests.ok(false, 'cash without a session must be refused');
  exception when sqlstate '55000' then
    perform tests.ok(true, 'cash taken at a counter needs an open session');
  end;

  v_pay := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_account, 'kind', 'payment', 'counterSessionId', v_session,
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 50000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 50000))));
  v_receipt := v_pay ->> 'receiptNo';
  perform tests.ok(length(v_receipt) = 16 and v_receipt like 'OPR%'
    and (v_pay ->> 'counterSessionId')::uuid = v_session,
    'the consultation receipt is numbered at collection and tied to the drawer');
  v_doc := billing.bill_json(v_bill);
  perform tests.ok(v_doc ->> 'status' = 'draft' and v_doc ->> 'billNo' is null
    and (v_doc ->> 'duePaise')::bigint = 0 and (v_doc ->> 'allocatedPaise')::bigint = 50000
    and (v_doc -> 'lines' -> 0 ->> 'locked')::boolean,
    'the fee is on the open bill and the consultation line is locked');
  v_line := (v_doc -> 'lines' -> 0 ->> 'id')::uuid;

  begin
    perform billing.remove_line(v_tenant, v_bill, v_line);
    perform tests.ok(false, 'a paid consultation must stay on the bill');
  exception when sqlstate '55000' then
    perform tests.ok(true, 'a paid line cannot be removed');
  end;
  begin
    update billing.bill_line set unit_price_paise = 1 where id = v_line;
    perform tests.ok(false, 'a paid line price must not change');
  exception when sqlstate '55000' then
    perform tests.ok(true, 'a paid line price cannot change');
  end;

  v_item := (billing.upsert_service_item(v_tenant, jsonb_build_object(
    'name', 'Wound dressing', 'category', 'procedure')) ->> 'id')::uuid;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and name = 'Standard' and branch_id is null and not is_deleted;
  perform billing.add_price(v_tenant, jsonb_build_object(
    'priceListId', v_list, 'serviceItemId', v_item, 'unitPricePaise', 15000, 'effectiveFrom', '2017-07-01'));
  v_doc := billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform tests.ok((v_doc ->> 'id')::uuid = v_bill and v_doc ->> 'status' = 'draft'
    and jsonb_array_length(v_doc -> 'lines') = 2
    and (v_doc ->> 'duePaise')::bigint = 15000
    and (v_doc -> 'lines' -> 0 ->> 'locked')::boolean
    and (v_doc -> 'lines' -> 1 ->> 'locked')::boolean = false,
    'a later procedure is added to the same open bill');

  v_pay2 := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_account, 'kind', 'payment', 'counterSessionId', v_session,
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 15000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 15000))));
  v_receipt2 := v_pay2 ->> 'receiptNo';
  perform tests.ok(right(v_receipt2, 9)::bigint = right(v_receipt, 9)::bigint + 1
    and (billing.bill_json(v_bill) ->> 'duePaise')::bigint = 0
    and (billing.bill_json(v_bill) ->> 'billNo') is null,
    'the procedure is collected on the same bill and the invoice is still unnumbered');

  v_refund := billing.request_refund(v_tenant, (v_pay ->> 'id')::uuid, jsonb_build_object(
    'amountPaise', 5000, 'mode', 'cash'));
  perform tests.ok(v_refund ->> 'kind' = 'refund' and (v_refund ->> 'counterSessionId')::uuid = v_session
    and (billing.bill_json(v_bill) ->> 'duePaise')::bigint = 5000,
    'a cash refund stays on the open drawer and gives the money back to the bill');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_other := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_other, jsonb_build_object('code', 'CONSULT'));
  v_link := billing.create_payment_link(v_tenant, v_other, jsonb_build_object('channel', 'qr', 'counterSessionId', v_session));
  v_hook := billing.apply_webhook('stub', jsonb_build_object(
    'eventId', gen_random_uuid()::text, 'providerOrderId', v_link ->> 'providerOrderId',
    'status', 'paid', 'amountPaise', 50000));
  perform tests.ok((v_hook ->> 'applied')::boolean and (v_hook ->> 'counterSessionId')::uuid = v_session
    and (select mode from billing.payment_tender t where t.payment_id = (v_hook ->> 'id')::uuid) = 'upi',
    'a webhook receipt keeps the cashier session and does not pretend to be cash');

  v_doc := billing.finalize_bill(v_tenant, v_bill);
  perform tests.ok(v_doc ->> 'status' = 'finalized' and length(v_doc ->> 'billNo') = 16
    and (v_doc ->> 'billNo') like 'OPB%' and (v_doc ->> 'duePaise')::bigint = 5000,
    'the invoice number is assigned when the bill is closed');
  begin
    perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
    perform tests.ok(false, 'a closed bill must not take another line');
  exception when sqlstate '55000' then
    perform tests.ok(true, 'closing the bill stops further lines');
  end;

  v_close := billing.close_session(v_tenant, v_session, jsonb_build_object('countedCashPaise', 60000));
  perform tests.ok((v_close ->> 'expectedCashPaise')::bigint = 60000
    and (v_close ->> 'variancePaise')::bigint = 0 and v_close ->> 'status' = 'closed',
    'expected cash is the consultation and the procedure, minus the cash refund, and not the UPI webhook');

  select id into v_line from billing.payment_tender where payment_id = (v_pay ->> 'id')::uuid;
  select id into v_second from billing.allocation where payment_id = (v_pay ->> 'id')::uuid and amount_paise > 0 limit 1;
  insert into t_money (payment_id, tender_id, allocation_id)
  values ((v_pay ->> 'id')::uuid, v_line, v_second);

  begin
    update billing.payment set amount_paise = amount_paise where id = (v_pay ->> 'id')::uuid;
    perform tests.ok(false, 'the billing role must not update a payment');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'updating a payment is rejected');
  end;
  begin
    update billing.payment set is_deleted = true where id = (v_pay ->> 'id')::uuid;
    perform tests.ok(false, 'a payment must not be soft-deleted');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'soft-delete is not a way to void a payment');
  end;
  begin
    update billing.payment_tender set amount_paise = 1 where id = v_line;
    perform tests.ok(false, 'a tender must not be updated');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'updating a tender is rejected');
  end;
  begin
    update billing.allocation set amount_paise = 1 where id = v_second;
    perform tests.ok(false, 'an allocation must not be updated');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'updating an allocation is rejected');
  end;
end
$$;

select tests.as_superuser();
select tests.throws_ok(
  format('update billing.payment set amount_paise = amount_paise where id = %L', (select payment_id from t_money)),
  '55000',
  'a payment update is rejected even for the table owner');
select tests.throws_ok(
  format('update billing.payment_tender set reference = ''x'' where id = %L', (select tender_id from t_money)),
  '55000',
  'a tender update is rejected even for the table owner');
select tests.throws_ok(
  format('update billing.allocation set amount_paise = amount_paise where id = %L', (select allocation_id from t_money)),
  '55000',
  'an allocation update is rejected even for the table owner');

-- An existing advance is an allocation, not a second receipt.
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_src uuid;
  v_bill uuid;
  v_account uuid;
  v_before bigint;
  v_advance bigint;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_src := (v_doc ->> 'accountId')::uuid;
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_src, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 20000))));
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  v_account := (v_doc ->> 'accountId')::uuid;
  perform tests.ok(v_account <> v_src, 'the advance lives on a different account from the bill');
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  select count(*) into v_before from billing.payment where tenant_id = v_tenant and not is_deleted;
  v_doc := billing.apply_advance(v_tenant, v_bill, jsonb_build_object('amountPaise', 20000));
  select advance_paise into v_advance from billing.patient_advance_v1
  where tenant_id = v_tenant and patient_id = v_patient;
  perform tests.ok(v_doc ->> 'status' = 'draft' and (v_doc ->> 'duePaise')::bigint = 30000
    and (v_doc ->> 'allocatedPaise')::bigint = 20000
    and coalesce(v_advance, 0) = 0
    and (select count(*) from billing.payment where tenant_id = v_tenant and not is_deleted) = v_before,
    'applying an advance allocates the existing receipt and does not issue another');
end
$$;

rollback;
