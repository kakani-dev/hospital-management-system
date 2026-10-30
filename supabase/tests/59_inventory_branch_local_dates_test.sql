-- #189: expiry and drug-licence checks use the branch-local date (20261030100000). Synthetic data; rolls back.
begin;

select tests.ok(
  inventory.branch_today('a1111111-0000-4000-8000-000000000001', '2026-10-29T19:00:00Z') = date '2026-10-30',
  '00:30 IST on 30 Oct is 30 Oct at an IST branch (UTC still says 29 Oct)');
select tests.ok(
  inventory.branch_today('a1111111-0000-4000-8000-000000000001', '2026-10-29T18:29:00Z') = date '2026-10-29',
  '23:59 IST on 29 Oct is still 29 Oct');
select tests.ok(
  inventory.branch_today('00000000-0000-4000-8000-0000000000ff', '2026-10-29T19:00:00Z') = date '2026-10-30',
  'an unknown branch falls back to Asia/Kolkata, never to the UTC session date');

select tests.ok(
  not exists (
    select 1 from pg_proc p
    where p.oid in ('inventory.guard_sale_store_licence()'::regprocedure,
                    'inventory.fefo_pick_v1(uuid, uuid, uuid, bigint)'::regprocedure,
                    'inventory.stock_on_hand(uuid, uuid, uuid, boolean)'::regprocedure,
                    'pharmacy.rx_json(uuid, uuid, uuid)'::regprocedure,
                    'pharmacy.dispense(uuid, uuid, jsonb)'::regprocedure)
      and p.prosrc ~* '\mcurrent_date\M'),
  'no pharmacy/stock expiry or licence check uses the UTC current_date any more');
select tests.ok(
  has_function_privilege('hms_svc_inventory', 'inventory.branch_today(uuid, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'inventory.branch_today(uuid, timestamptz)', 'execute'),
  'the inventory service can read the branch date; anon cannot');

-- A branch far ahead of UTC: the licence check follows the branch calendar.
update identity.branches set timezone_override = 'Pacific/Kiritimati' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.ok(
  inventory.branch_today('a1111111-0000-4000-8000-000000000002') = (now() at time zone 'Pacific/Kiritimati')::date,
  'a branch override zone decides the date');

do $$
declare
  v_today date := inventory.branch_today('a1111111-0000-4000-8000-000000000002');
  v_err text;
begin
  begin
    insert into inventory.store (tenant_id, branch_id, code, name, store_kind, drug_licence_no, licence_valid_to)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
            'ZZQA-59A', 'Zz-QA 59 lapsed', 'op_pharmacy', 'ZZQA-DL-59', v_today - 1);
  exception when check_violation then v_err := sqlerrm;
  end;
  perform tests.ok(v_err = 'a pharmacy needs a current drug licence',
    'a licence that ended yesterday (branch date) is refused');

  insert into inventory.store (tenant_id, branch_id, code, name, store_kind, drug_licence_no, licence_valid_to)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
          'ZZQA-59B', 'Zz-QA 59 today', 'op_pharmacy', 'ZZQA-DL-59B', v_today);
  perform tests.ok(true, 'a licence valid until today (branch date) is accepted');
end;
$$;

rollback;
