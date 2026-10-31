-- Owner dashboard KPIs (20261031220000). Synthetic Zz-QA data, relative dates; rolls back.
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

select tests.as_superuser();
select tests.ok(
  has_function_privilege('hms_svc_billing', 'billing.owner_kpis(uuid, date, date, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'billing.owner_kpis(uuid, date, date, uuid)', 'execute')
  and not has_function_privilege('anon', 'billing.owner_kpis(uuid, date, date, uuid)', 'execute'),
  'owner KPIs run only through the billing service');

create temporary table t_k (k text primary key, v jsonb) on commit drop;
grant all on table t_k to hms_svc_billing;

do $do$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_beta uuid := '22222222-2222-4222-8222-222222222222';
  v_main uuid := 'a1111111-0000-4000-8000-000000000001';
  v_asha uuid := 'aa000000-0000-4000-8000-000000000001';
  v_today date := inventory.branch_today('a1111111-0000-4000-8000-000000000001');
  v_before jsonb; v_after jsonb; v_beta_before jsonb; v_acct uuid; v_tok int;
begin
  perform tests.billing_as('0a000000-0000-4000-8000-000000000001');
  v_before := billing.owner_kpis(v_tenant, v_today - 6, v_today, v_main);
  perform tests.billing_as('0b000000-0000-4000-8000-000000000001');
  v_beta_before := billing.owner_kpis(v_beta, v_today - 6, v_today);
  perform tests.throws_ok(format('select billing.owner_kpis(%L::uuid, %L::date, %L::date)', v_tenant, v_today - 6, v_today),
    '42501', 'another tenant''s admin cannot read this hospital''s KPIs');

  perform tests.billing_as('0a000000-0000-4000-8000-000000000001');
  execute 'reset role';
  select coalesce(max(token_no), 0) + 1 into v_tok from appointment.queue_entries
   where tenant_id = v_tenant and branch_id = v_main and queue_date = v_today;
  insert into appointment.queue_entries (tenant_id, branch_id, queue_date, token_no, patient_id, status)
  values (v_tenant, v_main, v_today, v_tok, v_asha, 'done'),
         (v_tenant, v_main, v_today, v_tok + 1, v_asha, 'cancelled');
  insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values (v_tenant, v_main, 'c1111111-0000-4000-8000-000000000002', v_asha,
          (v_today - 1)::timestamp at time zone 'Asia/Kolkata' + interval '23 hours 40 minutes',
          (v_today - 1)::timestamp at time zone 'Asia/Kolkata' + interval '23 hours 55 minutes');
  update appointment.appointments set status = 'no_show'
   where tenant_id = v_tenant and patient_id = v_asha and starts_at = (v_today - 1)::timestamp at time zone 'Asia/Kolkata' + interval '23 hours 40 minutes';

  perform tests.billing_as('0a000000-0000-4000-8000-000000000002');
  v_acct := (billing.open_account(v_tenant, jsonb_build_object('patientId', v_asha, 'branchId', v_main)) ->> 'accountId')::uuid;
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object('accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 20000, 'reference', 'ZZQAUPI76'))));
  perform billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object('accountId', v_acct, 'kind', 'advance',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'card', 'amountPaise', 30000, 'reference', 'ZZQACARD76'))));

  perform tests.billing_as('0a000000-0000-4000-8000-000000000001');
  v_after := billing.owner_kpis(v_tenant, v_today - 6, v_today, v_main);
  insert into t_k values ('before', v_before), ('after', v_after);
  perform tests.ok(jsonb_array_length(v_after -> 'days') = 7 and v_after -> 'days' -> 6 ->> 'date' = v_today::text,
    'one row per day for the range');
  perform tests.ok((v_after #>> '{totals,opdVisits}')::int - (v_before #>> '{totals,opdVisits}')::int = 1,
    'OPD visits count a done token and ignore a cancelled one');
  perform tests.ok((v_after -> 'days' -> 5 ->> 'noShows')::int - (v_before -> 'days' -> 5 ->> 'noShows')::int = 1,
    'a late-evening no-show lands on its branch-local day');
  perform tests.ok((v_after #>> '{totals,collectedPaise}')::bigint - (v_before #>> '{totals,collectedPaise}')::bigint = 50000
    and (v_after #>> '{byMode,upi}')::bigint - coalesce((v_before #>> '{byMode,upi}')::bigint, 0) = 20000
    and (v_after #>> '{byMode,card}')::bigint - coalesce((v_before #>> '{byMode,card}')::bigint, 0) = 30000,
    'collections total and split by payment method');
  perform tests.throws_ok(format('select billing.owner_kpis(%L::uuid, %L::date, %L::date)', v_tenant, v_today - 92, v_today),
    '22023', 'range is capped at 92 days');
  perform tests.throws_ok(format('select billing.owner_kpis(%L::uuid, %L::date, %L::date)', v_tenant, v_today, v_today - 1),
    '22023', 'from after to is rejected');

  perform tests.billing_as('0a000000-0000-4000-8000-000000000003');
  perform tests.throws_ok(format('select billing.owner_kpis(%L::uuid, %L::date, %L::date)', v_tenant, v_today, v_today),
    '42501', 'staff without earnings access cannot open the owner dashboard');

  perform tests.billing_as('0b000000-0000-4000-8000-000000000001');
  perform tests.ok(billing.owner_kpis(v_beta, v_today - 6, v_today) -> 'totals' = v_beta_before -> 'totals',
    'another tenant''s KPIs do not include this hospital''s activity');
end;
$do$;

rollback;
