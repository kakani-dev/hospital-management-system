-- OP billing: computed totals, immutability, numbering, cash ceiling, approvals, RLS, outbox.
begin;

select tests.ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'billing' and c.relkind = 'r' and not c.relrowsecurity),
  'RLS is enabled on every billing table');

select tests.ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'billing' and table_name = 'bill'
      and column_name in ('total_paise', 'net_paise', 'balance_paise', 'round_off_paise')),
  'bill stores no total, balance or round-off');

select tests.ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'billing' and grantee in ('anon', 'PUBLIC', 'authenticated')),
  'anon, PUBLIC and authenticated have no table grants in billing');

select tests.ok(
  has_function_privilege('anon', 'billing.public_link(text)', 'execute')
  and has_function_privilege('anon', 'billing.apply_webhook(text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'billing.finalize_bill(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.caller_roles_v1(uuid)', 'execute')
  and not has_function_privilege('anon', 'appointment.appointment_billing_ref_v1(uuid, uuid)', 'execute'),
  'anon can open a receipt link and a webhook, and nothing else on the published surface');

select tests.ok(
  (select count(*) from appointment.appointment_billing_ref_v1(
     '11111111-1111-4111-8111-111111111111', 'e1111111-0000-4000-8000-000000000001')) = 1,
  'appointment_billing_ref_v1 returns ids for a seeded appointment');

select tests.ok(
  (select prosecdef and proconfig @> array['search_path=""']
     and has_function_privilege('hms_svc_billing', oid, 'execute')
     and not has_function_privilege('anon', oid, 'execute')
   from pg_proc where oid = 'audit.session_actor_id()'::regprocedure)
  and has_schema_privilege('hms_svc_billing', 'audit', 'USAGE')
  and not has_table_privilege('hms_svc_billing', 'audit.audit_log', 'select'),
  'the session actor is a security-definer function the billing role can call without reading the audit log');

-- --------------------------------------------------------------------- admin desk ----
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_second uuid;
  v_account uuid;
  v_line uuid;
  v_item uuid;
  v_list uuid;
  v_tax uuid;
  v_pay jsonb;
  v_pay2 jsonb;
  v_note jsonb;
  v_idem uuid := gen_random_uuid();
  v_first_no text;
  v_second_no text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  perform billing.ensure_defaults(v_tenant);
  select id into v_tax from billing.tax_code where tenant_id = v_tenant and code = 'EXEMPT' and not is_deleted;
  v_doc := billing.upsert_service_item(v_tenant, jsonb_build_object(
    'name', 'Round probe', 'category', 'procedure', 'taxCodeId', v_tax));
  v_item := (v_doc ->> 'id')::uuid;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and name = 'Standard' and branch_id is null and not is_deleted;
  perform billing.add_price(v_tenant, jsonb_build_object(
    'priceListId', v_list, 'serviceItemId', v_item, 'unitPricePaise', 5010, 'effectiveFrom', '2017-07-01'));
  begin
    perform billing.add_price(v_tenant, jsonb_build_object(
      'priceListId', v_list, 'serviceItemId', v_item, 'unitPricePaise', 6000, 'effectiveFrom', '2018-01-01'));
    perform tests.ok(false, 'overlapping prices must be rejected');
  exception when sqlstate '23P01' then
    perform tests.ok(true, 'price effective dates cannot overlap');
  end;

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  v_account := (v_doc ->> 'accountId')::uuid;
  v_doc := billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  perform tests.ok((v_doc ->> 'exactPaise')::bigint = 5010, 'exact paise is the snapshot, not a stored total');
  perform tests.ok((v_doc ->> 'totalPaise')::bigint = 5000, 'total rounds half away from zero to the rupee');
  perform tests.ok((v_doc ->> 'roundOffPaise')::bigint = -10, 'round-off is computed');
  perform tests.ok((v_doc ->> 'taxPaise')::bigint = 0 and (v_doc -> 'lines' -> 0 ->> 'taxRateBp')::int = 0,
    'OP procedure snapshots the exempt SAC 9993 rate');

  v_doc := billing.finalize_bill(v_tenant, v_bill);
  v_first_no := v_doc ->> 'billNo';
  perform tests.ok(v_doc ->> 'status' = 'finalized' and length(v_first_no) = 16 and v_first_no like 'OPB%',
    'finalized bill number is 16 characters');
  select id into v_line from billing.bill_line where bill_id = v_bill and not is_deleted;
  begin
    update billing.bill_line set unit_price_paise = 1 where id = v_line;
    perform tests.ok(false, 'a finalized line must not change');
  exception when sqlstate '55000' then
    perform tests.ok(true, 'a finalized line is immutable');
  end;

  v_pay := billing.record_payment(v_tenant, v_idem, jsonb_build_object(
    'accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 5000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 5000))));
  v_pay2 := billing.record_payment(v_tenant, v_idem, jsonb_build_object(
    'accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 5000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 5000))));
  perform tests.ok(v_pay ->> 'id' = v_pay2 ->> 'id', 'an idempotency key returns the original receipt');
  perform tests.ok((select due_paise from billing.bill_balance_v1 where bill_id = v_bill) = 0,
    'the balance view reaches zero after the allocation');

  begin
    perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
      'accountId', v_account, 'kind', 'advance',
      'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 20000000))));
    perform tests.ok(false, '₹2,00,000 cash must be refused');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'cash that reaches ₹2,00,000 in a day is refused');
  end;

  v_note := billing.create_credit_note(v_tenant, v_bill, jsonb_build_object(
    'lines', jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 1))));
  perform tests.ok(v_note ->> 'status' = 'finalized' and (v_note ->> 'billNo') like 'OPC%'
    and (v_note -> 'lines' -> 0 ->> 'quantity')::numeric = -1,
    'a credit note is the correction and carries a C series number');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_second := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_second, jsonb_build_object('code', 'CONSULT'));
  v_second_no := billing.finalize_bill(v_tenant, v_second) ->> 'billNo';
  perform tests.ok(right(v_second_no, 9)::bigint = right(v_first_no, 9)::bigint + 1,
    'bill numbers are gapless per branch, type and year');
end
$$;

select tests.as_superuser();
select tests.ok(exists (
  select 1 from messaging.outbox
  where event_type = 'billing.bill_finalized.v1' and source_service = 'billing'),
  'finalizing a bill publishes billing.bill_finalized.v1');

-- --------------------------------------------------------------------- desk discount ----
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_tax uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  execute 'set local role hms_svc_billing';
  select id into v_tax from billing.tax_code where tenant_id = v_tenant and code = 'EXEMPT' and not is_deleted;
  begin
    perform billing.upsert_service_item(v_tenant, jsonb_build_object(
      'name', 'Nope', 'category', 'other', 'taxCodeId', v_tax));
    perform tests.ok(false, 'a receptionist must not manage prices');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'price-list management is refused for the desk');
  end;
end
$$;

create temporary table t_billing_probe (bill_id uuid) on commit drop;
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_tax uuid;
  v_item uuid;
  v_list uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  select id into v_tax from billing.tax_code where tenant_id = v_tenant and code = 'EXEMPT' and not is_deleted;
  v_item := (billing.upsert_service_item(v_tenant, jsonb_build_object(
    'name', 'Large procedure', 'category', 'procedure', 'taxCodeId', v_tax)) ->> 'id')::uuid;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and name = 'Standard' and branch_id is null and not is_deleted;
  perform billing.add_price(v_tenant, jsonb_build_object(
    'priceListId', v_list, 'serviceItemId', v_item, 'unitPricePaise', 10000000, 'effectiveFrom', '2017-07-01'));
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  insert into t_billing_probe (bill_id) values (v_bill);
end
$$;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_bill uuid := (select bill_id from t_billing_probe);
  v_doc jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  execute 'set local role hms_svc_billing';
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object(
    'kind', 'percent_bp', 'value', 1000, 'reasonCode', 'hardship'));
  perform tests.ok(v_doc ->> 'status' = 'pending' and (v_doc ->> 'amountPaise')::bigint = 1000000,
    'a discount outside the cashier cap waits for an approver');
  perform tests.ok((select approver_id is null and requested_by = '0a000000-0000-4000-8000-000000000002'
                    from billing.approval_request where id = (v_doc ->> 'approvalId')::uuid),
    'a pending approval records the requester and not an approver yet');
end
$$;

-- --------------------------------------------------------------------- other tenant ----
do $$
declare
  v_bill uuid := (select bill_id from t_billing_probe);
  v_n bigint;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0b000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0b000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  select count(*) into v_n from billing.bill where id = v_bill;
  perform tests.ok(v_n = 0, 'another tenant cannot see the bill through RLS');
end
$$;

select tests.as_superuser();
set local session authorization hms_patients_login;
set local role hms_svc_patients;
select tests.throws_ok(
  'select count(*) from billing.bill',
  '42501',
  'the patients role cannot select billing.bill');
reset session authorization;

rollback;
