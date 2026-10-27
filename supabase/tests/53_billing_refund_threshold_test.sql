-- Refunds follow the tenant maker-checker threshold (#145, REF-001/002/006/007). Rolls back.
-- The exact boundary (#115) is whatever billing.needs_checker says; this file only checks
-- clearly-below / clearly-above amounts plus the configured threshold value itself.
begin;

insert into auth.users (id, email, role, aud) values
  ('0e530000-0000-4000-8000-000000000001', 'zz-qa-billing-145@medicore.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e530000-0000-4000-8000-000000000001', 'billing', 'active');

create or replace function pg_temp.act(p_user uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  execute 'set local role hms_svc_billing';
end $$;

do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_billing uuid := '0e530000-0000-4000-8000-000000000001';
  v_admin uuid := '0a000000-0000-4000-8000-000000000001';
  v_acct uuid;
  v_cash uuid;
  v_upi uuid;
  v_doc jsonb;
  v_n bigint;
  v_sess uuid;
begin
  perform pg_temp.act(v_admin);
  perform billing.ensure_defaults(t);
  perform billing.set_approval_settings(t, '{"makerCheckerThresholdPaise": 20000}');
  perform pg_temp.act(v_billing);
  v_sess := (billing.ensure_cashier_session(t, v_branch) ->> 'id')::uuid;
  v_acct := (billing.open_account(t, jsonb_build_object('patientId', v_patient, 'branchId', v_branch)) ->> 'accountId')::uuid;
  v_cash := (billing.record_payment(t, gen_random_uuid(), jsonb_build_object('accountId', v_acct, 'kind', 'advance', 'counterSessionId', v_sess,
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 100000)))) ->> 'id')::uuid;
  v_upi := (billing.record_payment(t, gen_random_uuid(), jsonb_build_object('accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 100000)))) ->> 'id')::uuid;

  -- REF-001: below the threshold completes straight away for a billing user.
  v_doc := billing.request_refund(t, v_upi, '{"amountPaise": 100, "mode": "upi"}');
  perform tests.ok(v_doc ->> 'kind' = 'refund',
    'a Rs 1 refund by a billing user completes without approval');
  v_doc := billing.request_refund(t, v_upi, '{"amountPaise": 5001, "mode": "upi"}');
  perform tests.ok(v_doc ->> 'kind' = 'refund', 'a Rs 50.01 refund completes without approval');
  v_doc := billing.request_refund(t, v_cash, '{"amountPaise": 19999, "mode": "cash"}');
  perform tests.ok(v_doc ->> 'kind' = 'refund',
    'a cash refund below the threshold completes using the open counter session');

  -- REF-002: above the threshold needs a checker.
  v_doc := billing.request_refund(t, v_upi, '{"amountPaise": 20001, "mode": "upi"}');
  perform tests.ok(v_doc ->> 'status' = 'pending' and v_doc ? 'approvalId', 'a Rs 200.01 refund goes to pending approval');

  -- The configured threshold is what counts, not a hard-coded Rs 200.
  perform pg_temp.act(v_admin);
  perform billing.set_approval_settings(t, '{"makerCheckerThresholdPaise": 0}');
  perform pg_temp.act(v_billing);
  v_doc := billing.request_refund(t, v_upi, '{"amountPaise": 100, "mode": "upi"}');
  perform tests.ok(v_doc ->> 'status' = 'pending', 'with threshold 0 every refund needs approval (REF-008)');
  perform pg_temp.act(v_admin);
  perform billing.set_approval_settings(t, '{"makerCheckerThresholdPaise": 50000}');
  perform pg_temp.act(v_billing);
  v_doc := billing.request_refund(t, v_upi, '{"amountPaise": 30000, "mode": "upi"}');
  perform tests.ok(v_doc ->> 'kind' = 'refund', 'raising the threshold lets a Rs 300 refund complete');

  -- REF-007: rejected up front, not parked as pending.
  select count(*) into v_n from billing.approval_request where tenant_id = t and action = 'refund' and status = 'pending';
  perform tests.throws_ok(format($q$select billing.request_refund(%L, %L, '{"amountPaise": 100, "mode": "cash"}')$q$, t, v_upi),
    '42501', 'a billing user cannot refund a UPI payment in cash');
  perform tests.throws_ok(format($q$select billing.request_refund(%L, %L, '{"amountPaise": 30000, "mode": "cash"}')$q$, t, v_upi),
    '42501', 'the cash-of-digital guard applies above the threshold too');

  -- REF-006: a cash refund with no open counter session is rejected, below or above the threshold.
  execute 'reset role';
  update billing.counter_session set status = 'closed' where tenant_id = t and status = 'open';
  perform pg_temp.act(v_billing);
  perform tests.throws_ok(format($q$select billing.request_refund(%L, %L, '{"amountPaise": 100, "mode": "cash"}')$q$, t, v_cash),
    '55000', 'a cash refund without an open counter session is rejected');
  perform tests.throws_ok(format($q$select billing.request_refund(%L, %L, '{"amountPaise": 60000, "mode": "cash"}')$q$, t, v_cash),
    '55000', 'a large cash refund without a session is rejected, not parked');
  execute 'reset role';
  perform tests.ok((select count(*) from billing.approval_request where tenant_id = t and action = 'refund' and status = 'pending') = v_n,
    'rejected refunds leave no pending approval behind');
end $$;

rollback;
