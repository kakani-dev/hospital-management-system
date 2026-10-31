-- #62: GL / Tally export. Ledger mapping per tenant and a balanced voucher feed with GST split,
-- round-off, credit notes, receipts and refunds. Relative dates. The transaction rolls back.
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

select tests.ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'billing' and c.relname in ('gl_ledger_map', 'gl_export_log')),
  'RLS is on for the ledger map and export log');
select tests.ok(
  (select bool_and(not has_function_privilege('anon', oid, 'execute') and not has_function_privilege('authenticated', oid, 'execute')
                   and has_function_privilege('hms_svc_billing', oid, 'execute'))
     from pg_proc where oid in ('billing.gl_vouchers(uuid,date,date,uuid)'::regprocedure,
                                'billing.gl_ledger_map_set(uuid,jsonb)'::regprocedure,
                                'billing.gl_ledger_map_get(uuid)'::regprocedure,
                                'billing.gl_export_record(uuid,date,date,uuid,text,integer,bigint)'::regprocedure)),
  'only the billing service can call the GL functions');

do $do$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_main uuid := 'a1111111-0000-4000-8000-000000000001';
  v_admin uuid := '0a000000-0000-4000-8000-000000000001';
  v_desk uuid := '0a000000-0000-4000-8000-000000000002';
  v_beta_admin uuid := '0b000000-0000-4000-8000-000000000001';
  v_asha uuid := 'aa000000-0000-4000-8000-000000000001';
  v_tax uuid; v_exempt uuid; v_item uuid; v_free uuid; v_odd uuid; v_list uuid;
  v_doc jsonb; v_bill uuid; v_bill2 uuid; v_draft uuid; v_acct uuid; v_pay uuid; v_note uuid; v_appr uuid; v_ref uuid;
  v_out jsonb; v_v jsonb; v_from date := current_date - 1; v_to date := current_date + 1;
begin
  perform tests.billing_as(v_admin);
  perform billing.ensure_defaults(v_tenant);
  perform billing.set_branch_profile(v_tenant, v_main, jsonb_build_object('gstin', '36AABCU9603R1ZM', 'legalName', 'Zz-QA Hospital'));
  perform tests.as_superuser();
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'GL18', '998311', false, 1800, current_date - 3650) returning id into v_tax;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'GL00', '999312', true, 0, current_date - 3650) returning id into v_exempt;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'GLPROC', 'Zz-QA GL procedure', 'procedure', v_tax) returning id into v_item;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'GLCONS', 'Zz-QA GL consult', 'consultation', v_exempt) returning id into v_free;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'GLODD', 'Zz-QA GL odd', 'lab', v_tax) returning id into v_odd;
  select id into v_list from billing.price_list
   where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, current_date - 3650), (v_tenant, v_list, v_free, 5000, current_date - 3650),
         (v_tenant, v_list, v_odd, 10010, current_date - 3650);

  -- permissions
  perform tests.billing_as(v_desk);
  perform tests.throws_ok(format('select billing.gl_vouchers(%L::uuid, %L::date, %L::date, null)', v_tenant, v_from, v_to),
    '42501', 'a receptionist cannot export the GL');
  perform tests.billing_as(v_beta_admin);
  perform tests.throws_ok(format('select billing.gl_ledger_map_get(%L::uuid)', v_tenant), '42501', 'another tenant cannot read the mapping');
  perform tests.throws_ok(format('select billing.gl_ledger_map_set(%L::uuid, %L::jsonb)', v_tenant, '[{"key":"round_off","name":"X"}]'),
    '42501', 'another tenant cannot change the mapping');

  perform tests.billing_as(v_admin);
  perform tests.throws_ok(format('select billing.gl_vouchers(%L::uuid, %L::date, %L::date, null)', v_tenant, v_to, v_from),
    '22023', 'to before from is rejected');
  perform tests.throws_ok(format('select billing.gl_vouchers(%L::uuid, %L::date, %L::date, null)', v_tenant, v_from - 500, v_to),
    '22023', 'more than 400 days is rejected');

  -- Bill 1: procedure 100 + 18% + exempt consult 50 = 168.00, paid UPI.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_bill := (v_doc ->> 'id')::uuid; v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_free));
  perform billing.finalize_bill(v_tenant, v_bill);
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 10000), jsonb_build_object('mode', 'card', 'amountPaise', 6800)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 16800))));
  v_pay := (v_doc ->> 'id')::uuid;
  -- Bill 2: odd paise 100.10 + 18.02 = 118.12 -> rounds to 118.00 (round-off -0.12), unpaid.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_bill2 := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill2, jsonb_build_object('serviceItemId', v_odd));
  perform billing.finalize_bill(v_tenant, v_bill2);
  -- Draft: never exported.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_draft := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_draft, jsonb_build_object('serviceItemId', v_item));
  -- Partial refund 84.00 -> value credit note.
  v_note := billing.credit_note_for_refund(v_tenant, v_pay, 8400);

  perform tests.as_superuser();
  insert into billing.approval_request (tenant_id, action, subject_type, subject_id, amount_paise, requested_by, status, approver_id, decided_at)
  values (v_tenant, 'refund', 'payment', v_pay, 8400, v_desk, 'approved', v_admin, now()) returning id into v_appr;
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, refund_of_payment_id, approval_id, received_at, credit_note_id)
  values (v_tenant, v_acct, 'ZZRF1', gen_random_uuid(), 'refund', 8400, v_pay, v_appr, now(), v_note) returning id into v_ref;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise) values (v_tenant, v_ref, 'cash', 8400);

  perform tests.billing_as(v_admin);
  v_out := billing.gl_vouchers(v_tenant, v_from, v_to, null);

  perform tests.ok(not exists (select 1 from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_draft::text),
    'a draft bill is not exported');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(v_out -> 'vouchers') v
      where (select sum((e ->> 'amountPaise')::bigint) from jsonb_array_elements(v -> 'entries') e) <> 0),
    'every voucher balances (debits = credits)');

  select v into v_v from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_bill::text;
  perform tests.ok(v_v ->> 'type' = 'sales', 'a final bill is a sales voucher');
  perform tests.ok(
    (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'party:self') = 16800,
    'the patient party is debited the bill total');
  perform tests.ok(
    (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'sales:procedure') = -10000
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'sales:consultation') = -5000,
    'income is credited per service category (exempt consult separate)');
  perform tests.ok(
    (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'gst:cgst' and (e ->> 'rateBp')::int = 900) = -900
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'gst:sgst' and (e ->> 'rateBp')::int = 900) = -900
    and not exists (select 1 from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'gst:igst'),
    'intra-state 18% splits into CGST 9% and SGST 9%; no IGST; zero lines dropped');

  select v into v_v from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_bill2::text;
  perform tests.ok(
    (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'round_off') = 12
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'party:self') = 11800,
    'round-off down is a 0.12 debit and the party gets the rounded 118.00');

  select v into v_v from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_note::text;
  perform tests.ok(v_v ->> 'type' = 'credit_note' and v_v ->> 'against' is not null
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'party:self') = -8400,
    'the credit note credits the party 84.00 and references the original bill');

  select v into v_v from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_pay::text;
  perform tests.ok(v_v ->> 'type' = 'receipt'
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'tender:upi') = 10000
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'tender:card') = 6800
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'party:self') = -16800,
    'a split-tender receipt debits UPI and card and credits the patient');

  select v into v_v from jsonb_array_elements(v_out -> 'vouchers') v where v ->> 'id' = v_ref::text;
  perform tests.ok(v_v ->> 'type' = 'refund'
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'tender:cash') = -8400
    and (select (e ->> 'amountPaise')::bigint from jsonb_array_elements(v_v -> 'entries') e where e ->> 'key' = 'party:self') = 8400,
    'a cash refund credits cash and debits the patient');

  v_out := billing.gl_vouchers(v_tenant, current_date + 5, current_date + 6, null);
  perform tests.ok(jsonb_array_length(v_out -> 'vouchers') = 0, 'a future period has no vouchers');

  -- mapping
  perform billing.gl_ledger_map_set(v_tenant, '[{"key":"round_off","name":"Rounding Off","group":"Indirect Expenses"},{"key":"tender:upi","name":"HDFC UPI"}]'::jsonb);
  v_doc := billing.gl_ledger_map_get(v_tenant);
  perform tests.ok(jsonb_array_length(v_doc -> 'overrides') = 2 and v_doc -> 'gstRates' @> '[1800]'::jsonb,
    'overrides are stored and GST rates are listed');
  perform billing.gl_ledger_map_set(v_tenant, '[{"key":"tender:upi","name":"  "}]'::jsonb);
  v_doc := billing.gl_ledger_map_get(v_tenant);
  perform tests.ok(jsonb_array_length(v_doc -> 'overrides') = 1, 'a blank name restores the default');
  perform tests.throws_ok(format('select billing.gl_ledger_map_set(%L::uuid, %L::jsonb)', v_tenant, '[{"key":"Bad Key","name":"X"}]'),
    '22023', 'an invalid ledger key is rejected');

  -- export log
  perform tests.ok(billing.gl_export_record(v_tenant, v_from, v_to, null, 'xml', 5, 100) is null, 'the first export has no prior');
  perform tests.ok(billing.gl_export_record(v_tenant, current_date, current_date, null, 'csv', 2, 50) ->> 'format' = 'xml',
    'an overlapping re-export reports the earlier export');
  perform tests.ok((billing.gl_ledger_map_get(v_tenant) -> 'lastExport' ->> 'format') in ('xml', 'csv'), 'the last export is shown');
end
$do$;

rollback;
