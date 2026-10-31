-- #65: day-end close beyond cash. Cash per drawer with reason and handover, card/UPI/bank settled per
-- account for the branch-day, advances/refunds summary, supervisor sign-off locking the day.
-- Relative dates (current_date). The transaction rolls back.
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
    where n.nspname = 'billing' and c.relname in ('cash_handover', 'day_settlement', 'day_signoff')),
  'RLS is on for handovers, settlements and sign-offs');
select tests.ok(
  (select bool_and(not has_function_privilege('anon', oid, 'execute') and not has_function_privilege('authenticated', oid, 'execute')
                   and has_function_privilege('hms_svc_billing', oid, 'execute'))
     from pg_proc where oid in ('billing.day_close_summary(uuid,uuid,date)'::regprocedure,
                                'billing.close_counter_session(uuid,uuid,jsonb)'::regprocedure,
                                'billing.receive_handover(uuid,uuid)'::regprocedure,
                                'billing.record_settlements(uuid,uuid,date,jsonb)'::regprocedure,
                                'billing.signoff_day(uuid,uuid,date,jsonb)'::regprocedure)),
  'only the billing service can call the day-close functions');

create temporary table t_ids (k text primary key, v uuid) on commit drop;
grant all on table t_ids to hms_svc_billing;

do $do$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_main uuid := 'a1111111-0000-4000-8000-000000000001';
  v_admin uuid := '0a000000-0000-4000-8000-000000000001';
  v_desk uuid := '0a000000-0000-4000-8000-000000000002';
  v_beta_admin uuid := '0b000000-0000-4000-8000-000000000001';
  v_asha uuid := 'aa000000-0000-4000-8000-000000000001';
  v_day date;
  v_doc jsonb; v_acct uuid; v_desk_s uuid; v_admin_s uuid; v_h uuid; v_s jsonb; v_m jsonb;
begin
  perform tests.billing_as(v_desk);
  v_desk_s := (billing.ensure_cashier_session(v_tenant, v_main) ->> 'id')::uuid;
  select business_date into v_day from billing.counter_session where id = v_desk_s;
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main));
  v_acct := (v_doc ->> 'accountId')::uuid;
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance', 'counterSessionId', v_desk_s,
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'cash', 'amountPaise', 50000))));
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 20000, 'reference', 'ZZUPI1'))));
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'card', 'amountPaise', 30000, 'reference', 'ZZCARD1'))));

  v_s := billing.day_close_summary(v_tenant, v_main, v_day);
  perform tests.ok((v_s -> 'cash' ->> 'expectedPaise')::bigint >= 50000
    and (select (x ->> 'expectedPaise')::bigint from jsonb_array_elements(v_s -> 'methods') x where x ->> 'mode' = 'upi') = 20000
    and (select (x ->> 'expectedPaise')::bigint from jsonb_array_elements(v_s -> 'methods') x where x ->> 'mode' = 'card') = 30000
    and (v_s -> 'advances' ->> 'amountPaise')::bigint = 100000
    and (v_s -> 'blockers') ? 'open_sessions' and (v_s -> 'blockers') ? 'unsettled_methods',
    'summary shows cash, UPI and card expected, advances and what blocks sign-off');

  perform tests.throws_ok(format('select billing.close_counter_session(%L::uuid, %L::uuid, %L::jsonb)', v_tenant, v_desk_s,
    jsonb_build_object('countedCashPaise', billing.expected_cash_paise(v_desk_s) - 1000)), '22023', 'a short count needs a reason');
  perform tests.throws_ok(format('select billing.close_counter_session(%L::uuid, %L::uuid, %L::jsonb)', v_tenant, v_desk_s,
    jsonb_build_object('countedCashPaise', 100, 'handoverPaise', 200)), '22023', 'cannot hand over more than counted');
  v_doc := billing.close_counter_session(v_tenant, v_desk_s, jsonb_build_object(
    'countedCashPaise', billing.expected_cash_paise(v_desk_s) - 1000, 'reason', '  Change   given short ', 'handoverPaise', 10000));
  perform tests.ok((v_doc ->> 'variancePaise')::bigint = -1000 and (v_doc ->> 'handoverPaise')::bigint = 10000,
    'the cashier closes with a reason and leaves cash for the next shift');
  perform tests.ok((select variance_reason from billing.counter_close where counter_session_id = v_desk_s and mode = 'cash') = 'Change given short',
    'the reason is stored trimmed');
  select id into v_h from billing.cash_handover where from_session_id = v_desk_s;
  perform tests.throws_ok(format('select billing.receive_handover(%L::uuid, %L::uuid)', v_tenant, v_h), '42501',
    'the outgoing cashier cannot receive their own handover');

  perform tests.billing_as(v_admin);
  v_doc := billing.receive_handover(v_tenant, v_h);
  v_admin_s := (v_doc ->> 'toSessionId')::uuid;
  perform tests.ok((select opening_float_paise from billing.counter_session where id = v_admin_s) >= 10000,
    'the incoming cashier''s drawer float includes the handed-over cash');
  perform tests.throws_ok(format('select billing.receive_handover(%L::uuid, %L::uuid)', v_tenant, v_h), '55000',
    'a handover is received once');
  perform tests.throws_ok(format('select billing.signoff_day(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day, '{}'),
    '55000', 'cannot sign off with a drawer still open');
  perform billing.close_counter_session(v_tenant, v_admin_s, jsonb_build_object('countedCashPaise', billing.expected_cash_paise(v_admin_s)));

  perform tests.billing_as(v_desk);
  perform tests.throws_ok(format('select billing.record_settlements(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day,
    '{"items":[{"mode":"upi","settledPaise":19000}]}'), '22023', 'a UPI shortfall needs a reason');
  perform tests.throws_ok(format('select billing.record_settlements(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day,
    '{"items":[{"mode":"cash","settledPaise":1}]}'), '22023', 'cash is counted per drawer, not settled');
  perform billing.record_settlements(v_tenant, v_main, v_day, jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('mode', 'upi', 'settledPaise', 19000, 'reason', 'Gateway fee deducted'),
    jsonb_build_object('mode', 'card', 'settledPaise', 30000))));
  perform billing.record_settlements(v_tenant, v_main, v_day, '{"items":[{"mode":"card","settledPaise":30000}]}'::jsonb);
  perform tests.ok((select count(*) from billing.day_settlement where branch_id = v_main and business_date = v_day and mode = 'card' and not is_deleted) = 1,
    're-entering a settlement updates it, no duplicate');
  perform tests.throws_ok(format('select billing.signoff_day(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day, '{}'),
    '42501', 'a cashier cannot sign off the day');

  perform tests.billing_as(v_beta_admin);
  perform tests.throws_ok(format('select billing.day_close_summary(%L::uuid, %L::uuid, %L::date)', v_tenant, v_main, v_day),
    '42501', 'another tenant cannot read the day close');

  perform tests.billing_as(v_admin);
  -- a late card payment after settlement makes it stale
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'card', 'amountPaise', 5000, 'reference', 'ZZCARD2'))));
  perform tests.throws_ok(format('select billing.signoff_day(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day, '{}'),
    '55000', 'a payment after settlement must be re-settled before sign-off');
  perform tests.billing_as(v_desk);
  perform billing.record_settlements(v_tenant, v_main, v_day, '{"items":[{"mode":"card","settledPaise":35000}]}'::jsonb);
  perform tests.billing_as(v_admin);
  v_s := billing.signoff_day(v_tenant, v_main, v_day, '{"note":"Zz-QA checked"}'::jsonb);
  perform tests.ok(v_s -> 'signoff' ->> 'signedBy' = v_admin::text and (v_s -> 'signoff' ->> 'cashVariancePaise')::bigint = -1000
    and (v_s -> 'signoff' ->> 'otherVariancePaise')::bigint = -1000 and jsonb_array_length(v_s -> 'blockers') = 0,
    'the supervisor signs off with cash and UPI variances recorded');
  perform tests.ok((select bool_and(status = 'reconciled') from billing.counter_session where id in (v_desk_s, v_admin_s)),
    'sign-off reconciles the closed drawers');
  perform tests.throws_ok(format('select billing.signoff_day(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day, '{}'),
    '55000', 'a day is signed off once');
  perform tests.throws_ok(format('select billing.record_settlements(%L::uuid, %L::uuid, %L::date, %L::jsonb)', v_tenant, v_main, v_day,
    '{"items":[{"mode":"card","settledPaise":1}]}'), '55000', 'a signed-off day is locked');
  insert into t_ids values ('x', v_admin_s);
end
$do$;

rollback;
