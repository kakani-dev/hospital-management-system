-- Earnings and CA registers. Every case is one assertion. The transaction rolls back.
-- Money is integer paise. Dates are the branch-local day (Asia/Kolkata), not the UTC day.
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
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'billing' and c.relname = 'bill'),
  'RLS stays enabled on billing.bill');

select tests.ok(
  exists (select 1 from pg_constraint where conname = 'payment_idem_key' and contype = 'u'),
  'two payments with one idempotency key cannot both commit');

select tests.ok(
  (select not has_function_privilege('anon', oid, 'execute')
      and not has_function_privilege('authenticated', oid, 'execute')
      and has_function_privilege('hms_svc_billing', oid, 'execute')
   from pg_proc where oid = 'billing.earnings_report(uuid,date,date,uuid,text,integer,integer)'::regprocedure),
  'only the billing service role can execute the earnings report');

select tests.ok(
  not has_table_privilege('anon', 'billing.earnings_line_v', 'select')
  and not has_table_privilege('authenticated', 'billing.earnings_line_v', 'select')
  and has_table_privilege('hms_svc_billing', 'billing.earnings_line_v', 'select'),
  'anon and authenticated cannot select the earnings views');

select tests.ok(
  (timestamptz '2026-03-31 19:00:00+00' at time zone 'Asia/Kolkata')::date = date '2026-04-01'
  and (timestamptz '2026-01-31 18:29:00+00' at time zone 'Asia/Kolkata')::date = date '2026-01-31'
  and (timestamptz '2026-01-31 19:00:00+00' at time zone 'Asia/Kolkata')::date = date '2026-02-01',
  'IST midnight is 18:30 UTC, so 19:00 UTC is the next local day');

-- Case and whitespace are not roles. A new user avoids the existing membership unique key.
insert into auth.users (id, email, aud, role) values
  ('0a000000-0000-4000-8000-0000000000e5', 'not-a-role@alpha.example', 'authenticated', 'authenticated');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
    ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e5', null, 'Accountant', 'active')$$,
  '23514', 'a role that differs only by case is rejected');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
    ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e5', null, ' accountant ', 'active')$$,
  '23514', 'a role with surrounding whitespace is rejected');

insert into auth.users (id, email, aud, role) values
  ('0a000000-0000-4000-8000-0000000000e4', 'accounts@alpha.example', 'authenticated', 'authenticated');
insert into identity.user_profiles (id, email, display_name) values
  ('0a000000-0000-4000-8000-0000000000e4', 'accounts@alpha.example', 'Alpha Accounts (synthetic)');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e4', null, 'accountant', 'active');
-- Branch-scoped billing clerk: has the report permission, but only at main campus.
insert into auth.users (id, email, aud, role) values
  ('0a000000-0000-4000-8000-0000000000e6', 'billing-desk@alpha.example', 'authenticated', 'authenticated');
insert into identity.user_profiles (id, email, display_name) values
  ('0a000000-0000-4000-8000-0000000000e6', 'billing-desk@alpha.example', 'Alpha Billing Desk (synthetic)');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e6', 'a1111111-0000-4000-8000-000000000001', 'billing', 'active');

do $do$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_beta uuid := '22222222-2222-4222-8222-222222222222';
  v_main uuid := 'a1111111-0000-4000-8000-000000000001';
  v_east uuid := 'a1111111-0000-4000-8000-000000000002';
  v_admin uuid := '0a000000-0000-4000-8000-000000000001';
  v_desk uuid := '0a000000-0000-4000-8000-000000000002';
  v_beta_admin uuid := '0b000000-0000-4000-8000-000000000001';
  v_accountant uuid := '0a000000-0000-4000-8000-0000000000e4';
  v_biller uuid := '0a000000-0000-4000-8000-0000000000e6';
  v_asha uuid := 'aa000000-0000-4000-8000-000000000001';
  v_meera uuid := 'aa000000-0000-4000-8000-000000000003';
  v_general uuid := 'c1111111-0000-4000-8000-000000000002';
  v_visiting uuid := 'c1111111-0000-4000-8000-000000000001';
  v_tax uuid;
  v_odd_tax uuid;
  v_item uuid;
  v_odd_item uuid;
  v_list uuid;
  v_doc jsonb;
  v_bill uuid;
  v_acct uuid;
  v_march uuid;
  v_april uuid;
  v_east_bill uuid;
  v_void uuid;
  v_jan uuid;
  v_feb uuid;
  v_odd uuid;
  v_pay_march uuid;
  v_pay_april uuid;
  v_idem uuid := '45e00000-0000-4000-8000-000000000001';
  v_cash uuid;
  v_card uuid;
  v_credit uuid;
  v_approval uuid;
  v_refund uuid;
  v_note uuid;
  v_report jsonb;
  v_again jsonb;
  v_may jsonb;
  v_focus jsonb;
  v_total bigint;
begin
  perform tests.billing_as(v_desk);
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, null, null)', v_tenant),
    '42501', 'a receptionist is denied before date validation');
  perform tests.billing_as(v_beta_admin);
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, null, null, null)', v_tenant, '2026-04-01', '2026-04-30'),
    '42501', 'a beta admin cannot read alpha earnings');
  perform tests.billing_as(v_biller);
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, %L::uuid, null, null, null)', v_tenant, '2026-04-01', '2026-04-30', v_east),
    '42501', 'a main-campus billing clerk cannot open the east branch report');

  perform tests.billing_as(v_admin);
  perform billing.ensure_defaults(v_tenant);
  v_doc := billing.set_branch_profile(v_tenant, v_main, jsonb_build_object('gstin', '36aabcu9603r1zm', 'legalName', 'Alpha Hospital'));
  perform tests.ok(v_doc ->> 'gstin' = '36AABCU9603R1ZM', 'a GSTIN is stored in uppercase');
  perform billing.set_branch_profile(v_tenant, v_east, jsonb_build_object('gstin', '29AABCU9603R1ZM', 'legalName', 'Alpha East'));

  perform tests.as_superuser();
  update billing.branch_profile set doc_prefix = 'MN' where tenant_id = v_tenant and branch_id = v_main;
  update billing.branch_profile set doc_prefix = 'ES' where tenant_id = v_tenant and branch_id = v_east;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'T18E', '998311', false, 1800, date '2017-07-01') returning id into v_tax;
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'T05E', '998312', false, 500, date '2017-07-01') returning id into v_odd_tax;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'PROC18E', 'Earnings procedure', 'procedure', v_tax) returning id into v_item;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'PROC05E', 'Odd paise procedure', 'procedure', v_odd_tax) returning id into v_odd_item;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, date '2017-07-01'),
         (v_tenant, v_list, v_odd_item, 10010, date '2017-07-01');
  update patient.patients set first_name = '  Meera  ' where id = v_meera;

  perform tests.billing_as(v_admin);
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_march := (v_doc ->> 'id')::uuid;
  v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_march, jsonb_build_object('serviceItemId', v_item, 'quantity', 100, 'practitionerId', v_general));
  v_doc := billing.finalize_bill(v_tenant, v_march);
  perform tests.ok((v_doc ->> 'totalPaise')::bigint = 1180000, 'March qty 100 at 18 percent is ₹11,800.00');
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 1180000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_march, 'amountPaise', 1180000))));
  v_pay_march := (v_doc ->> 'id')::uuid;

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_april := (v_doc ->> 'id')::uuid;
  v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_april, jsonb_build_object('serviceItemId', v_item, 'quantity', 88, 'practitionerId', v_general));
  v_doc := billing.finalize_bill(v_tenant, v_april);
  perform tests.ok((v_doc ->> 'totalPaise')::bigint = 1038400, 'April qty 88 is 12 percent under March');
  v_doc := billing.record_payment(v_tenant, v_idem, jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 1038400)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_april, 'amountPaise', 1038400))));
  v_pay_april := (v_doc ->> 'id')::uuid;
  v_again := billing.record_payment(v_tenant, v_idem, jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 1038400)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_april, 'amountPaise', 1038400))));
  perform tests.ok(v_again ->> 'id' = v_pay_april::text
    and (select count(*) from billing.payment where tenant_id = v_tenant and idempotency_key = v_idem) = 1,
    'retrying the same payment returns the original receipt');
  begin
    perform billing.record_payment(v_tenant, v_idem, jsonb_build_object(
      'accountId', v_acct, 'kind', 'payment',
      'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 1)),
      'allocations', jsonb_build_array(jsonb_build_object('billId', v_april, 'amountPaise', 1))));
    perform tests.ok(false, 'a reused payment key with a different amount must fail');
  exception when sqlstate '23505' then
    perform tests.ok(true, 'a reused payment key with a different amount hits the unique key');
  end;

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_meera, 'branchId', v_east));
  v_east_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_east_bill, jsonb_build_object('serviceItemId', v_item, 'quantity', 10, 'practitionerId', v_visiting));
  v_doc := billing.finalize_bill(v_tenant, v_east_bill);
  perform tests.ok((v_doc ->> 'totalPaise')::bigint = 118000 and v_doc -> 'supplier' ->> 'gstin' = '29AABCU9603R1ZM',
    'east April is unpaid and keeps its own GSTIN');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_void := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_void, jsonb_build_object('serviceItemId', v_item, 'quantity', 1, 'practitionerId', v_general));
  update billing.bill set status = 'cancelled_draft' where id = v_void;

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_jan := (v_doc ->> 'id')::uuid;
  v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_jan, jsonb_build_object('serviceItemId', v_item, 'quantity', 1, 'practitionerId', v_general));
  perform billing.finalize_bill(v_tenant, v_jan);
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 11800)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_jan, 'amountPaise', 11800))));

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_feb := (v_doc ->> 'id')::uuid;
  v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.add_line(v_tenant, v_feb, jsonb_build_object('serviceItemId', v_item, 'quantity', 1, 'practitionerId', v_general));
  perform billing.finalize_bill(v_tenant, v_feb);
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 11800)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_feb, 'amountPaise', 11800))));

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_odd := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_odd, jsonb_build_object('serviceItemId', v_odd_item, 'quantity', 1, 'practitionerId', v_general));
  v_doc := billing.finalize_bill(v_tenant, v_odd);
  perform tests.ok((v_doc ->> 'totalPaise')::bigint = 10500, '10511 paise rounds to the nearest rupee, ₹105.00');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_acct := (v_doc ->> 'accountId')::uuid;

  perform tests.as_superuser();
  alter table billing.bill disable trigger bill_immutable;
  alter table billing.payment disable trigger payment_money_immutable;
  update billing.bill set finalized_at = timestamptz '2026-03-10 09:00:00+05:30' where id = v_march;
  update billing.payment p set received_at = timestamptz '2026-03-10 09:00:00+05:30'
    from billing.allocation a where a.payment_id = p.id and a.bill_id = v_march;
  update billing.bill set finalized_at = timestamptz '2026-04-10 09:00:00+05:30' where id = v_april;
  update billing.payment set received_at = timestamptz '2026-04-10 09:00:00+05:30' where id = v_pay_april;
  update billing.bill set finalized_at = timestamptz '2026-04-10 09:00:00+05:30' where id = v_east_bill;
  update billing.bill
    set supplier_gstin = null, supplier_state_code = null, finalized_at = timestamptz '2026-01-31 18:29:00+00'
    where id = v_jan;
  update billing.payment p set received_at = timestamptz '2026-01-31 18:29:00+00'
    from billing.allocation a where a.payment_id = p.id and a.bill_id = v_jan;
  update billing.bill set finalized_at = timestamptz '2026-01-31 19:00:00+00' where id = v_feb;
  update billing.payment p set received_at = timestamptz '2026-01-31 19:00:00+00'
    from billing.allocation a where a.payment_id = p.id and a.bill_id = v_feb;
  update billing.bill set finalized_at = timestamptz '2026-06-15 09:00:00+05:30' where id = v_odd;
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, received_at)
  values (v_tenant, v_acct, 'CASHIN20260815', '45e00000-0000-4000-8000-0000000000c1', 'advance', 20000, timestamptz '2026-08-15 10:00:00+05:30')
  returning id into v_cash;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise) values (v_tenant, v_cash, 'cash', 20000);
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, received_at)
  values (v_tenant, v_acct, 'CARDIN20260815', '45e00000-0000-4000-8000-0000000000c2', 'advance', 3000, timestamptz '2026-08-15 10:00:00+05:30')
  returning id into v_card;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise) values (v_tenant, v_card, 'card', 3000);
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, received_at)
  values (v_tenant, v_acct, 'CREDIN20260815', '45e00000-0000-4000-8000-0000000000c3', 'advance', 5000, timestamptz '2026-08-15 10:00:00+05:30')
  returning id into v_credit;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise) values (v_tenant, v_credit, 'credit', 5000);
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, requested_by, approver_id, status, decided_at)
  values (v_tenant, 'refund', 'payment', v_cash, 5000, v_admin, v_admin, 'approved', timestamptz '2026-08-15 11:00:00+05:30')
  returning id into v_approval;
  insert into billing.payment (
    tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, refund_of_payment_id, approval_id, received_at)
  select tenant_id, account_id, 'CASHRF20260815', '45e00000-0000-4000-8000-0000000000c5', 'refund', 5000, v_cash, v_approval,
         timestamptz '2026-08-15 11:00:00+05:30'
  from billing.payment where id = v_cash;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise)
  select tenant_id, id, 'cash', 5000 from billing.payment where receipt_no = 'CASHRF20260815' and tenant_id = v_tenant;
  alter table billing.bill enable trigger bill_immutable;
  alter table billing.payment enable trigger payment_money_immutable;

  perform tests.billing_as(v_admin);
  v_report := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, 'month', null, null);
  v_again := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, 'month', null, null);
  perform tests.ok(v_report = v_again, 'a retry returns the same report');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, %L, null, null)', v_tenant, '2026-04-01', '2026-04-30', 'nope'),
    '22023', 'a bad grain is rejected');
  v_again := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, 'month', null, null);
  perform tests.ok(v_report = v_again, 'a failed request rolls back and the next read still succeeds');

  perform tests.ok((v_report -> 'focus' ->> 'grossBilledPaise')::bigint = 1156400, 'April gross is main plus east');
  perform tests.ok((v_report -> 'focus' ->> 'billCount')::bigint = 2, 'a cancelled draft is not a bill');
  perform tests.ok((v_report -> 'focus' ->> 'refundsPaise')::bigint = 0, 'a May refund is not an April refund');
  perform tests.ok((v_report -> 'focus' -> 'deltas' -> 'grossBilled' ->> 'pct')::numeric = -2.0,
    'tenant April versus March is 2 percent, not a divide by zero');
  perform tests.ok(
    v_report -> 'insights' @> '["Alpha Main Campus revenue down 12% vs last month"]'::jsonb,
    'main campus is down 12 percent versus last month');
  perform tests.ok(
    v_report -> 'insights' @> '["Alpha East Clinic revenue is new vs last month"]'::jsonb,
    'a branch with a zero previous period is new, not a percent');
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'branches') b
      where b ->> 'name' = 'Alpha East Clinic' and b ->> 'direction' = 'new' and b -> 'periodGrowthPct' = 'null'::jsonb),
    'east growth has no percent when the previous period is zero');
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'branches') b
      where b ->> 'name' = 'Alpha Main Campus' and (b ->> 'periodGrowthPct')::numeric = -12),
    'main campus growth is exactly minus 12 percent');
  perform tests.ok(
    v_report -> 'insights' @> '["Alpha Main Campus is 89.8% of hospital revenue"]'::jsonb,
    'main campus is 89.8 percent of hospital revenue');
  perform tests.ok(
    not exists (select 1 from jsonb_array_elements_text(v_report -> 'insights') line where line like 'Revenue %'),
    'a 2 percent tenant move does not raise a year or month insight');
  perform tests.ok((v_report -> 'ageing' ->> 'b0To30Paise')::bigint = 118000
    and (v_report -> 'ageing' ->> 'b31To60Paise')::bigint = 0
    and (v_report -> 'ageing' ->> 'b90PlusPaise')::bigint = 0,
    'the unpaid east bill is 20 days old on 30 April');
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'sales') s
      where s ->> 'party' = 'Meera Synthetic-Alpha'),
    'a party name with extra spaces is trimmed');
  perform tests.ok(
    coalesce((select sum((g ->> 'creditNoteCount')::int) from jsonb_array_elements(v_report -> 'gstr1') g), 0) = 0,
    'April GSTR-1 has no credit note');
  perform tests.ok(
    v_report -> 'insights' @> '["Dr. Alpha General (synthetic) leads doctor revenue"]'::jsonb
    and v_report -> 'insights' @> '["Dr. Visiting Consultant (synthetic) has the lowest doctor revenue"]'::jsonb,
    'two doctors are ranked from the bills');

  perform tests.as_superuser();
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, requested_by, approver_id, status, decided_at)
  values (v_tenant, 'refund', 'payment', v_pay_april, 11800, v_admin, v_admin, 'approved', now())
  returning id into v_approval;
  perform tests.billing_as(v_admin);
  v_refund := billing.insert_refund(v_tenant, v_pay_april, 11800, 'upi', 'synthetic', v_approval, gen_random_uuid(), null);
  select credit_note_id into v_note from billing.payment where id = v_refund;
  perform tests.as_superuser();
  alter table billing.bill disable trigger bill_immutable;
  alter table billing.payment disable trigger payment_money_immutable;
  update billing.payment set received_at = timestamptz '2026-05-15 10:00:00+05:30' where id = v_refund;
  update billing.bill set finalized_at = timestamptz '2026-05-15 10:00:00+05:30' where id = v_note;
  alter table billing.bill enable trigger bill_immutable;
  alter table billing.payment enable trigger payment_money_immutable;

  perform tests.billing_as(v_admin);
  v_again := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, 'month', null, null);
  perform tests.ok((v_again -> 'focus' ->> 'grossBilledPaise')::bigint = 1156400
    and (v_again -> 'focus' ->> 'refundsPaise')::bigint = 0
    and coalesce((select sum((g ->> 'creditNoteCount')::int) from jsonb_array_elements(v_again -> 'gstr1') g), 0) = 0,
    'a credit note dated in May does not change April gross, refunds or GSTR-1');
  v_may := billing.earnings_report(v_tenant, date '2026-05-01', date '2026-05-31', null, 'month', null, null);
  perform tests.ok((v_may -> 'focus' ->> 'grossBilledPaise')::bigint = 0
    and (v_may -> 'focus' ->> 'refundsPaise')::bigint = 11800
    and jsonb_array_length(v_may -> 'creditNotes') = 1
    and (v_may -> 'creditNotes' -> 0 ->> 'totalPaise')::bigint = 11800,
    'May holds the refund and the credit note, and gross stays invoices only');

  v_report := billing.earnings_report(v_tenant, date '2026-01-31', date '2026-01-31', null, 'day', null, null);
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_jan))
    and not exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_feb))
    and exists (select 1 from jsonb_array_elements(v_report -> 'sales') s
                where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_jan) and s ->> 'gstin' = '36AABCU9603R1ZM'),
    '31 Jan 18:29 UTC is still 31 Jan in IST, and a bill without a GSTIN snapshot reports the branch GSTIN (#92)');
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'gstr1') g where g ->> 'gstin' = '36AABCU9603R1ZM' and g ->> 'month' = '2026-01')
    and not exists (select 1 from jsonb_array_elements(v_report -> 'gstr1') g where g ->> 'gstin' = 'UNREGISTERED'),
    'GSTR-1 summary groups the unsnapshotted bill under the branch GSTIN, not UNREGISTERED (#92)');
  perform tests.ok(
    (billing.bill_document(v_tenant, v_jan) -> 'supplier' ->> 'gstin') = '36AABCU9603R1ZM',
    'the bill document and the report agree on the GSTIN (#92)');

  perform tests.as_superuser();
  update billing.branch_profile set gstin = null where tenant_id = v_tenant and branch_id = v_main;
  perform tests.billing_as(v_admin);
  v_report := billing.earnings_report(v_tenant, date '2026-01-31', date '2026-02-01', null, 'day', null, null);
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'sales') s
            where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_jan) and s ->> 'gstin' = 'UNREGISTERED')
    and exists (select 1 from jsonb_array_elements(v_report -> 'sales') s
            where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_feb) and s ->> 'gstin' = '36AABCU9603R1ZM'),
    'no snapshot and no branch GSTIN is UNREGISTERED; a bill snapshot wins over the branch profile (#92)');
  perform tests.as_superuser();
  update billing.branch_profile set gstin = '36AABCU9603R1ZM' where tenant_id = v_tenant and branch_id = v_main;
  perform tests.billing_as(v_admin);
  v_report := billing.earnings_report(v_tenant, date '2026-02-01', date '2026-02-01', null, 'day', null, null);
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_feb))
    and not exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where (s ->> 'invoiceNumber') = (select bill_no from billing.bill where id = v_jan)),
    '31 Jan 19:00 UTC is 1 Feb in IST and lands in the February report');

  v_report := billing.earnings_report(v_tenant, null, null, null, null, 2026, 4);
  perform tests.ok(v_report ->> 'from' = '2027-01-01' and v_report ->> 'to' = '2027-03-31',
    'Q4 of FY 2026 is 1 Jan through 31 Mar of the next calendar year');
  v_report := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, null, 2025, null);
  perform tests.ok(v_report ->> 'from' = '2025-04-01' and v_report ->> 'to' = '2026-03-31'
    and exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where s ->> 'invoiceNumber' = (select bill_no from billing.bill where id = v_march))
    and not exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where s ->> 'invoiceNumber' = (select bill_no from billing.bill where id = v_april)),
    'the server financial year wins over client dates and stops on 31 March');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, 1999, null)', v_tenant),
    '22023', 'financial year 1999 is rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, 2101, null)', v_tenant),
    '22023', 'financial year 2101 is rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, 2026, 0)', v_tenant),
    '22023', 'quarter 0 is rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, 2026, 5)', v_tenant),
    '22023', 'quarter 5 is rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, null, null, null, null, null, null)', v_tenant),
    '22023', 'missing dates are rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, null, null, null)', v_tenant, '2026-04-30', '2026-04-01'),
    '22023', 'a reversed range is rejected');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, null, null, null)', v_tenant, '2020-01-01', '2021-02-05'),
    '22023', 'a range longer than 400 days is rejected');
  v_report := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, '  Month  ', null, null);
  perform tests.ok(v_report ->> 'grain' = 'month', 'grain is trimmed and matched ignoring case');

  v_report := billing.earnings_report(v_tenant, date '2026-06-01', date '2026-06-30', null, 'month', null, null);
  perform tests.ok((v_report -> 'focus' ->> 'grossBilledPaise')::bigint = 10500
    and (v_report -> 'focus' ->> 'cgstPaise')::bigint = 251
    and (v_report -> 'focus' ->> 'sgstPaise')::bigint = 250,
    'odd tax paise go to CGST and the bill total rounds to the nearest rupee');

  v_report := billing.earnings_report(v_tenant, date '2026-08-15', date '2026-08-15', null, 'day', null, null);
  perform tests.ok((v_report -> 'focus' ->> 'collectedPaise')::bigint = 23000
    and (v_report -> 'focus' ->> 'refundsPaise')::bigint = 5000
    and (v_report -> 'focus' ->> 'netEarningsPaise')::bigint = 18000
    and exists (select 1 from jsonb_array_elements(v_report -> 'paymentModes') m
      where m ->> 'mode' = 'credit' and (m ->> 'collectedPaise')::bigint = 5000)
    and (v_report -> 'dayEndCash' -> 0 ->> 'netCashPaise')::bigint = 15000
    and (v_report -> 'dayEndCash' -> 0 ->> 'cardPaise')::bigint = 3000,
    'credit mode is shown but excluded from collected, and day-end net cash is cash in minus cash out');

  v_report := billing.earnings_report(v_tenant, date '2020-01-01', date '2020-01-31', null, 'month', null, null);
  perform tests.ok((v_report -> 'focus' ->> 'grossBilledPaise')::bigint = 0
    and v_report -> 'focus' -> 'deltas' -> 'grossBilled' ->> 'direction' = 'flat'
    and v_report -> 'focus' -> 'deltas' -> 'grossBilled' -> 'pct' = 'null'::jsonb
    and v_report -> 'focus' ->> 'averageBillPaise' is null
    and v_report -> 'insights' @> '["No bills in this period."]'::jsonb,
    'a period with no bills is flat, with no percent and no average');

  perform tests.as_superuser();
  insert into billing.bill (tenant_id, account_id, bill_kind, status, bill_no, payer_type, finalized_at, finalized_by)
  select v_tenant, (select account_id from billing.bill where id = v_april), 'final', 'finalized',
         'Z' || lpad(g::text, 4, '0'), 'self', timestamptz '2024-01-15 10:00:00+05:30', v_admin
  from generate_series(1, 501) g;
  perform tests.billing_as(v_admin);
  v_report := billing.earnings_report(v_tenant, date '2024-01-01', date '2024-01-31', null, 'month', null, null);
  perform tests.ok((v_report ->> 'truncated')::boolean
    and jsonb_array_length(v_report -> 'sales') = 500,
    'a large month keeps 500 sales rows and says the register was cut');

  v_focus := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', v_main, 'month', null, null);
  perform tests.ok(v_focus ->> 'level' = 'branch'
    and not exists (select 1 from jsonb_array_elements(v_focus -> 'sales') s where s ->> 'party' = 'Meera Synthetic-Alpha'),
    'drilling into main campus drops east invoices from the register');

  perform tests.billing_as(v_admin);
  perform tests.ok((select count(*) from billing.earnings_line_v) > 0, 'an admin can read earnings lines');
  perform tests.billing_as(v_desk);
  perform tests.ok((select count(*) from billing.earnings_line_v) = 0, 'a receptionist reads no earnings lines');
  perform tests.as_anon();
  perform tests.throws_ok('select count(*) from billing.earnings_line_v', '42501', 'anon cannot read the earnings line view');
  perform tests.authenticate_as('reception@alpha.example');
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, null, null, null)', v_tenant, '2026-04-01', '2026-04-30'),
    '42501', 'the authenticated role cannot execute the report');

  perform tests.billing_as(v_accountant);
  perform tests.ok((billing.earnings_report(v_tenant, date '2020-01-01', date '2020-01-31', null, 'month', null, null) -> 'focus' ->> 'grossBilledPaise')::bigint = 0,
    'an active accountant can read the report');
  perform tests.as_superuser();
  update identity.memberships set status = 'suspended' where user_id = v_accountant and tenant_id = v_tenant;
  perform tests.billing_as(v_accountant);
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, null, null, null, null)', v_tenant, '2020-01-01', '2020-01-31'),
    '42501', 'a suspended accountant cannot read the report');

  perform tests.billing_as(v_admin);
  execute 'set local role authenticated';
  perform identity.soft_delete_branch(v_east);
  perform appointment.soft_delete_practitioner(v_visiting);
  perform patient.soft_delete_patient(v_meera, 'synthetic earnings history');
  perform tests.billing_as(v_admin);
  v_report := billing.earnings_report(v_tenant, date '2026-04-01', date '2026-04-30', null, 'month', null, null);
  perform tests.ok(
    exists (select 1 from jsonb_array_elements(v_report -> 'branches') b
      where b ->> 'name' = 'Alpha East Clinic' and (b ->> 'deleted')::boolean and (b ->> 'grossBilledPaise')::bigint = 118000)
    and exists (select 1 from jsonb_array_elements(v_report -> 'doctors') d where d ->> 'name' = 'Dr. Visiting Consultant (synthetic)')
    and exists (select 1 from jsonb_array_elements(v_report -> 'sales') s where s ->> 'party' = 'Meera Synthetic-Alpha'),
    'deleted branch, doctor and patient stay in the history with their amounts');
  perform tests.billing_as(v_biller);
  perform tests.throws_ok(
    format('select billing.earnings_report(%L::uuid, %L::date, %L::date, %L::uuid, null, null, null)', v_tenant, '2026-04-01', '2026-04-30', v_east),
    'P0002', 'a deleted branch is not found for a clerk who cannot see deleted history');
end
$do$;

select tests.as_superuser();
rollback;
