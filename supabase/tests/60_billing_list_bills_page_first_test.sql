-- #125/#126: the bills list stays fast with hundreds of bills and keeps its scope rules
-- (20261030110000). Synthetic data; rolls back.
begin;

-- 330 synthetic bills (300 finalized-shape rows, 30 drafts) with 3 lines each on branch 1,
-- inserted raw so the test does not depend on the finalize flow.
set local session_replication_role = replica;
insert into billing.billing_account (id, tenant_id, patient_id, branch_id, account_type, source_ref_type, created_by, updated_by)
select ('ac' || lpad(to_hex(g), 6, '0') || '-0000-4000-8000-000000000060')::uuid, '11111111-1111-4111-8111-111111111111',
       'aa000000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 'walk_in', 'none',
       '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'
from generate_series(1, 330) g;
insert into billing.bill (id, tenant_id, account_id, bill_kind, status, bill_no, finalized_at, finalized_by,
                          created_by, updated_by, created_on)
select ('b1' || lpad(to_hex(g), 6, '0') || '-0000-4000-8000-000000000060')::uuid, '11111111-1111-4111-8111-111111111111',
       ('ac' || lpad(to_hex(g), 6, '0') || '-0000-4000-8000-000000000060')::uuid, 'final',
       case when g % 11 = 0 then 'draft' else 'finalized' end,
       case when g % 11 = 0 then null else 'ZQ60-' || g end,
       case when g % 11 = 0 then null else now() end,
       case when g % 11 = 0 then null else '0a000000-0000-4000-8000-000000000001'::uuid end,
       '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001',
       now() + interval '1 day' - g * interval '1 minute'
from generate_series(1, 330) g;
insert into billing.bill_line (tenant_id, bill_id, line_no, service_item_id, price_list_item_id, quantity,
                               unit_price_paise, tax_rate_bp, created_by, updated_by)
select '11111111-1111-4111-8111-111111111111', ('b1' || lpad(to_hex(g), 6, '0') || '-0000-4000-8000-000000000060')::uuid, n,
       gen_random_uuid(), gen_random_uuid(), 1, 10000 * n, 0,
       '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'
from generate_series(1, 330) g, generate_series(1, 3) n;
set local session_replication_role = origin;
-- Fresh planner statistics so the timing check measures the query, not a cold-stats plan
-- (CI timed out at ~60 s on unanalyzed tables while the same file ran in 0.4 s locally).
analyze billing.bill; analyze billing.billing_account; analyze billing.bill_line; analyze billing.payment; analyze patient.patients;

create temporary table t60 (k text primary key, v jsonb, ms numeric) on commit drop;
grant all on t60 to hms_svc_billing, hms_svc_identity;

select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local role hms_svc_billing;
do $$
declare
  v_t timestamptz;
begin
  v_t := clock_timestamp();
  insert into t60 values ('all', billing.list_bills('11111111-1111-4111-8111-111111111111', null, null, null, null),
    extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();
  insert into t60 values ('empty', billing.list_bills('11111111-1111-4111-8111-111111111111', '  ', null, null, null),
    extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();
  insert into t60 values ('finalized', billing.list_bills('11111111-1111-4111-8111-111111111111', 'finalized', null, null, null),
    extract(epoch from clock_timestamp() - v_t) * 1000);
  insert into t60 values ('draft', billing.list_bills('11111111-1111-4111-8111-111111111111', 'draft', null, null, null), null);
  insert into t60 values ('bogus', billing.list_bills('11111111-1111-4111-8111-111111111111', 'bogus', null, null, null), null);
end
$$;
reset role;

select tests.ok(jsonb_array_length((select v from t60 where k = 'all')) = 200, 'no filter returns the newest 200 bills');
select tests.ok((select v from t60 where k = 'empty') = (select v from t60 where k = 'all'), 'a blank status is the same as no filter');
select tests.ok(jsonb_array_length((select v from t60 where k = 'finalized')) = 200
  and not exists (select 1 from jsonb_array_elements((select v from t60 where k = 'finalized')) e where e ->> 'status' <> 'finalized'),
  'the finalized filter returns only finalized bills');
select tests.ok(jsonb_array_length((select v from t60 where k = 'draft')) >= 30, 'the draft filter still works');
select tests.ok((select v from t60 where k = 'bogus') = '[]'::jsonb, 'an unknown status returns an empty list');
select tests.ok((select ms from t60 where k = 'all') < 2000 and (select ms from t60 where k = 'finalized') < 2000,
  'the bills list answers in under 2 s with 330+ bills (was ~4.4 s locally, 30 s timeout live)');
select tests.ok(
  (select e ->> 'id' from jsonb_array_elements((select v from t60 where k = 'all')) with ordinality x(e, i) where i = 1)
    = 'b1000001-0000-4000-8000-000000000060',
  'the newest bill comes first');
select tests.ok(
  (select (e ->> 'totalPaise')::bigint = 60000 and (e ->> 'duePaise')::bigint = 60000
   from jsonb_array_elements((select v from t60 where k = 'all')) e
   where e ->> 'id' = 'b1000001-0000-4000-8000-000000000060'),
  'totals and dues are still computed for the page (3 lines: 100 + 200 + 300 rupees)');
select tests.ok(
  exists (select 1 from jsonb_array_elements((select v from t60 where k = 'all')) e
          where e ? 'billNo' and e ? 'billKind' and e ? 'patientId' and e ? 'branchId' and e ? 'createdOn'),
  'the row shape is unchanged');
select tests.ok(
  (select e ->> 'patientName' is not null and e ->> 'patientMrn' = (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-000000000001')
   from jsonb_array_elements((select v from t60 where k = 'all')) e
   where e ->> 'id' = 'b1000001-0000-4000-8000-000000000060'),
  '#124: each row carries the patient name and MRN');

-- Scope: definer must not widen access.
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '0d000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0d000000-0000-4000-8000-000000000001', true);
set local role hms_svc_billing;
select tests.throws_ok($$select billing.list_bills('11111111-1111-4111-8111-111111111111', null, null, null, null)$$,
  '42501', 'a doctor without billing.view cannot list bills');
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
select tests.throws_ok($$select billing.list_bills('11111111-1111-4111-8111-111111111111', null, 'a1111111-0000-4000-8000-000000000002', null, null)$$,
  '42501', 'a branch-1 receptionist cannot ask for branch 2');
select tests.throws_ok($$select billing.list_bills('22222222-2222-4222-8222-222222222222', null, null, null, null)$$,
  '42501', 'another tenant''s id is refused');
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
select tests.throws_ok($$select billing.list_bills('11111111-1111-4111-8111-111111111111', null, '00000000-0000-4000-8000-0000000000ff', null, null)$$,
  'P0002', 'an unknown branch is not found');
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
set local role hms_svc_billing;
select tests.throws_ok($$select billing.list_bills('11111111-1111-4111-8111-111111111111', null, null, null, null)$$,
  '42501', 'no signed-in user, no list (the definer owner must not leak bills)');
reset role;
select tests.ok(not has_function_privilege('anon', 'billing.list_bills(uuid, text, uuid, date, date)', 'execute'),
  'anon cannot call the bills list');

rollback;
