-- cross-schema: approved (audit.* triggers, identity.current_tenant_ids()/current_branch_ids() in RLS, identity.has_tenant_permission via billing.assert_permission and the published identity.branch_local_date_v1 read)
-- #283: opening a counter never reuses a drawer from an earlier business day (branch local date).
-- An open drawer whose business_date is before today is marked 'stale': it takes no new money, stays
-- on its own day's Day end as a blocker until counted (close it there), and today's collections go
-- to a fresh session dated today. Cash and refunds are then counted on the same business date.
set local lock_timeout = '5s';
set local statement_timeout = '120s';


alter table billing.counter_session drop constraint if exists counter_session_status;
alter table billing.counter_session add constraint counter_session_status
  check (status in ('open', 'stale', 'closed', 'reconciled'));
alter table billing.counter_session add column if not exists stale_at timestamptz;

create or replace function billing.retire_stale_sessions(p_tenant_id uuid, p_branch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer;
begin
  update billing.counter_session s set status = 'stale', stale_at = pg_catalog.now()
  from billing.counter c
  where c.id = s.counter_id and c.branch_id = p_branch_id
    and s.tenant_id = p_tenant_id and s.status = 'open' and not s.is_deleted
    and s.business_date < identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function billing.retire_stale_sessions(uuid, uuid) is
  '#283: marks open drawers from an earlier business day at this branch as stale (no new money; count them on their own Day end).';

create or replace function billing.assert_counter_session(
  p_tenant_id uuid, p_session_id uuid, p_branch_id uuid, p_required boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_cashier uuid;
  v_branch uuid;
  v_day date;
begin
  if p_session_id is null then
    if p_required then
      raise exception 'cash taken at a counter needs an open session' using errcode = '55000';
    end if;
    return;
  end if;
  select s.status, s.cashier_id, c.branch_id, s.business_date
    into v_status, v_cashier, v_branch, v_day
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.id = p_session_id and s.tenant_id = p_tenant_id and not s.is_deleted;
  if v_status is null then
    raise exception 'counter session not found' using errcode = 'P0002';
  end if;
  if v_status <> 'open' then
    raise exception 'counter session is not open' using errcode = '55000';
  end if;
  if v_day is distinct from identity.branch_local_date_v1(v_branch, pg_catalog.now()) then
    -- #283: a drawer left open from an earlier business day never takes today's money.
    raise exception 'counter session is from an earlier business day; open the counter again for today' using errcode = '55000';
  end if;
  if v_branch is distinct from p_branch_id then
    raise exception 'counter session is for another branch' using errcode = '42501';
  end if;
  if not billing.bypass_acl() and v_cashier is distinct from audit.session_actor_id() then
    raise exception 'counter session belongs to another cashier' using errcode = '42501';
  end if;
end;
$$;

create or replace function billing.ensure_cashier_session(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cashier uuid := audit.session_actor_id();
  v_name text;
  v_counter uuid;
  v_session uuid;
  v_day date;
  v_opened boolean := false;
  v_holder uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  if v_cashier is null then
    raise exception 'a counter session needs a signed-in cashier' using errcode = '42501';
  end if;
  perform billing.retire_stale_sessions(p_tenant_id, p_branch_id);
  select s.id, s.business_date into v_session, v_day
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = v_cashier
    and s.status = 'open'
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is not null then
    return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', false);
  end if;
  v_name := 'C' || replace(v_cashier::text, '-', '');
  insert into billing.counter (tenant_id, branch_id, name)
  values (p_tenant_id, p_branch_id, v_name)
  on conflict (tenant_id, branch_id, name) do nothing;
  select id into v_counter from billing.counter
  where tenant_id = p_tenant_id and branch_id = p_branch_id and name = v_name and not is_deleted;
  if v_counter is null then
    raise exception 'counter not found' using errcode = 'P0002';
  end if;
  v_day := identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
  insert into billing.counter_session (tenant_id, counter_id, cashier_id, business_date, opening_float_paise)
  values (p_tenant_id, v_counter, v_cashier, v_day, 0)
  on conflict (counter_id) where status = 'open' and not is_deleted
  do nothing
  returning id into v_session;
  if v_session is null then
    select id, cashier_id into v_session, v_holder
    from billing.counter_session
    where counter_id = v_counter and status = 'open' and not is_deleted;
    if v_holder is distinct from v_cashier then
      raise exception 'counter session belongs to another cashier' using errcode = '42501';
    end if;
  else
    v_opened := true;
  end if;
  return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', v_opened);
end;
$$;

create or replace function billing.find_cashier_session(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cashier uuid := audit.session_actor_id();
  v_session uuid;
  v_day date;
  v_today date;
  v_stale jsonb;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  v_today := identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'businessDate', s.business_date) order by s.business_date), '[]'::jsonb)
    into v_stale
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id and s.cashier_id = v_cashier and c.branch_id = p_branch_id and not s.is_deleted
    and (s.status = 'stale' or (s.status = 'open' and s.business_date < v_today));
  select s.id, s.business_date into v_session, v_day
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = v_cashier
    and s.status = 'open'
    and s.business_date = v_today
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is null then
    return jsonb_build_object('id', null, 'staleSessions', v_stale);
  end if;
  return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', false, 'staleSessions', v_stale);
end;
$$;

create or replace function billing.open_session(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_counter billing.counter%rowtype;
  v_id uuid;
  v_day date;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_counter from billing.counter
  where id = (p_body ->> 'counterId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  if v_counter.id is null then
    raise exception 'counter not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_counter.branch_id);
  perform billing.retire_stale_sessions(p_tenant_id, v_counter.branch_id);
  v_day := identity.branch_local_date_v1(v_counter.branch_id, pg_catalog.now());
  insert into billing.counter_session (tenant_id, counter_id, cashier_id, business_date, opening_float_paise)
  values (p_tenant_id, v_counter.id, audit.session_actor_id(), v_day, coalesce((p_body ->> 'openingFloatPaise')::bigint, 0))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'businessDate', v_day);
end;
$$;

create or replace function billing.refund_session(p_tenant_id uuid, p_branch_id uuid, p_mode text, p_source_session uuid, p_requested uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_session uuid;
  v_status text;
  v_branch uuid;
  v_day date;
  v_today date := identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
begin
  if p_requested is not null then
    perform billing.assert_counter_session(p_tenant_id, p_requested, p_branch_id, true);
    return p_requested;
  end if;
  if p_source_session is not null then
    select s.status, c.branch_id, s.business_date into v_status, v_branch, v_day
    from billing.counter_session s
    join billing.counter c on c.id = s.counter_id
    where s.id = p_source_session and s.tenant_id = p_tenant_id and not s.is_deleted;
    if v_status = 'open' and v_branch is not distinct from p_branch_id and v_day = v_today then
      return p_source_session;
    end if;
  end if;
  select s.id into v_session
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = audit.session_actor_id()
    and s.status = 'open'
    and s.business_date = v_today
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is not null then
    return v_session;
  end if;
  if p_mode = 'cash' then
    raise exception 'a cash refund needs an open counter session for today' using errcode = '55000';
  end if;
  return null;
end;
$$;

create or replace function billing.close_session(p_tenant_id uuid, p_session_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_session billing.counter_session%rowtype;
  v_expected bigint;
  v_counted bigint := (p_body ->> 'countedCashPaise')::bigint;
  v_variance bigint;
  v_approval uuid := nullif(p_body ->> 'approvalId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_session from billing.counter_session
  where id = p_session_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_session.id is null then
    raise exception 'session not found' using errcode = 'P0002';
  end if;
  if v_session.status not in ('open', 'stale') then
    raise exception 'session is not open' using errcode = '55000';
  end if;
  v_expected := billing.expected_cash_paise(p_session_id);
  v_variance := coalesce(v_counted, 0) - coalesce(v_expected, 0);
  if v_variance <> 0 and (
    v_approval is null
    or not exists (
      select 1 from billing.approval_request a
      where a.id = v_approval and a.tenant_id = p_tenant_id and a.action = 'cash_variance'
        and a.status = 'approved' and a.amount_paise >= abs(v_variance) and not a.is_deleted)
  ) then
    raise exception 'a cash variance needs an approved override' using errcode = '42501';
  end if;
  insert into billing.counter_close (tenant_id, counter_session_id, mode, counted_paise, variance_approval_id, closed_by)
  values (p_tenant_id, p_session_id, 'cash', coalesce(v_counted, 0), v_approval, audit.session_actor_id());
  update billing.counter_session set status = 'closed', closed_at = pg_catalog.now() where id = p_session_id;
  return jsonb_build_object('id', p_session_id, 'expectedCashPaise', v_expected, 'countedCashPaise', v_counted, 'variancePaise', v_variance, 'status', 'closed');
end;
$$;

create or replace function billing.close_counter_session(p_tenant_id uuid, p_session_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_session billing.counter_session%rowtype;
  v_branch uuid;
  v_counted bigint;
  v_handover bigint := coalesce(nullif(p_body ->> 'handoverPaise', '')::bigint, 0);
  v_expected bigint;
  v_reason text := billing.clean_reason(p_body ->> 'reason');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_session from billing.counter_session
  where id = p_session_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_session.id is null then
    raise exception 'counter session not found' using errcode = 'P0002';
  end if;
  select branch_id into v_branch from billing.counter where id = v_session.counter_id;
  perform billing.assert_branch(p_tenant_id, v_branch);
  if v_session.status not in ('open', 'stale') then
    raise exception 'counter session is already closed' using errcode = '55000';
  end if;
  if v_session.cashier_id is distinct from audit.session_actor_id()
     and not (billing.bypass_acl() or identity.has_tenant_permission(p_tenant_id, 'billing.counter_reconcile')) then
    raise exception 'only the cashier or a supervisor can close this drawer' using errcode = '42501';
  end if;
  perform billing.assert_day_open(p_tenant_id, v_branch, v_session.business_date);
  if jsonb_typeof(p_body -> 'countedCashPaise') <> 'number' then
    raise exception 'countedCashPaise is required' using errcode = '22023';
  end if;
  v_counted := (p_body ->> 'countedCashPaise')::bigint;
  if v_counted < 0 then
    raise exception 'counted cash cannot be negative' using errcode = '22023';
  end if;
  if v_handover < 0 or v_handover > v_counted then
    raise exception 'cash handed over must be between zero and the counted cash' using errcode = '22023';
  end if;
  if char_length(coalesce(v_reason, '')) > 200 or char_length(coalesce(p_body ->> 'note', '')) > 200 then
    raise exception 'reason and note must be 200 characters or fewer' using errcode = '22023';
  end if;
  v_expected := billing.expected_cash_paise(p_session_id);
  if v_counted <> v_expected and v_reason is null then
    raise exception 'a reason is required when counted cash differs from expected' using errcode = '22023';
  end if;
  insert into billing.counter_close (tenant_id, counter_session_id, mode, counted_paise, expected_paise, variance_reason, closed_by)
  values (p_tenant_id, p_session_id, 'cash', v_counted, v_expected,
          case when v_counted <> v_expected then v_reason end, audit.session_actor_id());
  if v_handover > 0 then
    insert into billing.cash_handover (tenant_id, branch_id, from_session_id, amount_paise, note)
    values (p_tenant_id, v_branch, p_session_id, v_handover, billing.clean_reason(p_body ->> 'note'));
  end if;
  update billing.counter_session set status = 'closed', closed_at = pg_catalog.now() where id = p_session_id;
  return jsonb_build_object('sessionId', p_session_id, 'status', 'closed', 'expectedCashPaise', v_expected,
    'countedCashPaise', v_counted, 'variancePaise', v_counted - v_expected, 'handoverPaise', v_handover);
end;
$$;

create or replace function billing.day_close_summary(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_actor uuid := audit.session_actor_id();
  v_sessions jsonb;
  v_methods jsonb;
  v_flow jsonb;
  v_signoff jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_cash_exp bigint;
  v_cash_cnt bigint;
  v_cash_var bigint;
  v_other_var bigint;
  v_expected_total bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);

  select coalesce(jsonb_agg(jsonb_build_object(
      'sessionId', s.id, 'counterId', s.counter_id, 'counterName', c.name, 'cashierId', s.cashier_id,
      'mine', s.cashier_id is not distinct from v_actor, 'status', s.status,
      'openedAt', s.opened_at, 'closedAt', s.closed_at,
      'openingFloatPaise', s.opening_float_paise,
      'expectedCashPaise', billing.expected_cash_paise(s.id),
      'countedCashPaise', cc.counted_paise,
      'variancePaise', cc.counted_paise - coalesce(cc.expected_paise, billing.expected_cash_paise(s.id)),
      'varianceReason', cc.variance_reason,
      'handover', case when h.id is null then null else jsonb_build_object(
        'id', h.id, 'amountPaise', h.amount_paise, 'note', h.note,
        'receivedBy', h.received_by, 'receivedAt', h.received_at) end
    ) order by s.opened_at), '[]'::jsonb),
    coalesce(sum(billing.expected_cash_paise(s.id)), 0),
    coalesce(sum(cc.counted_paise), 0),
    coalesce(sum(cc.counted_paise - coalesce(cc.expected_paise, billing.expected_cash_paise(s.id))), 0)
  into v_sessions, v_cash_exp, v_cash_cnt, v_cash_var
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and c.branch_id = p_branch_id
  left join billing.counter_close cc on cc.counter_session_id = s.id and cc.mode = 'cash' and not cc.is_deleted
  left join billing.cash_handover h on h.from_session_id = s.id and not h.is_deleted
  where s.tenant_id = p_tenant_id and s.business_date = p_on and not s.is_deleted;

  select coalesce(jsonb_agg(jsonb_build_object(
      'mode', m.mode, 'paymentAccountId', m.account_id, 'label', m.label,
      'receivedPaise', m.received, 'refundedPaise', m.refunded, 'expectedPaise', m.expected, 'count', m.n,
      'settledPaise', d.settled_paise, 'variancePaise', d.settled_paise - m.expected,
      'reason', d.reason, 'recordedBy', d.recorded_by, 'recordedAt', d.updated_on,
      'stale', d.id is not null and d.expected_paise <> m.expected
    ) order by m.mode, m.label nulls last), '[]'::jsonb),
    coalesce(sum(d.settled_paise - m.expected) filter (where d.id is not null), 0)
  into v_methods, v_other_var
  from (
    select coalesce(e.mode, d0.mode) as mode, coalesce(e.payment_account_id, d0.payment_account_id) as account_id,
           coalesce(e.label, pa.label, 'Unassigned') as label,
           coalesce(e.received_paise, 0) as received, coalesce(e.refunded_paise, 0) as refunded,
           coalesce(e.expected_paise, 0) as expected, coalesce(e.n, 0) as n
    from billing.noncash_expected(p_tenant_id, p_branch_id, p_on) e
    full join (select * from billing.day_settlement
               where tenant_id = p_tenant_id and branch_id = p_branch_id and business_date = p_on and not is_deleted) d0
      on d0.mode = e.mode and d0.payment_account_id is not distinct from e.payment_account_id
    left join billing.payment_account pa on pa.id = d0.payment_account_id
  ) m
  left join billing.day_settlement d on d.tenant_id = p_tenant_id and d.branch_id = p_branch_id
    and d.business_date = p_on and not d.is_deleted and d.mode = m.mode
    and d.payment_account_id is not distinct from m.account_id;

  select jsonb_build_object(
      'advances', jsonb_build_object('count', count(distinct p.id) filter (where p.kind = 'advance'),
        'amountPaise', coalesce(sum(t.amount_paise) filter (where p.kind = 'advance'), 0)),
      'refunds', jsonb_build_object('count', count(distinct p.id) filter (where p.kind = 'refund'),
        'amountPaise', coalesce(sum(t.amount_paise) filter (where p.kind = 'refund'), 0)),
      'credit', jsonb_build_object('count', count(distinct p.id) filter (where t.mode = 'credit' and p.kind <> 'refund'),
        'amountPaise', coalesce(sum(t.amount_paise) filter (where t.mode = 'credit' and p.kind <> 'refund'), 0)),
      'byMode', coalesce((select jsonb_object_agg(z.mode, jsonb_build_object('advancePaise', z.adv, 'refundPaise', z.ref))
        from (select t2.mode, coalesce(sum(t2.amount_paise) filter (where p2.kind = 'advance'), 0) as adv,
                     coalesce(sum(t2.amount_paise) filter (where p2.kind = 'refund'), 0) as ref
              from billing.payment p2
              join billing.billing_account a2 on a2.id = p2.account_id and a2.tenant_id = p2.tenant_id
              join billing.payment_tender t2 on t2.payment_id = p2.id and not t2.is_deleted
              where p2.tenant_id = p_tenant_id and not p2.is_deleted and a2.branch_id = p_branch_id
                and p2.kind in ('advance', 'refund')
                and identity.branch_local_date_v1(a2.branch_id, p2.received_at) = p_on
              group by t2.mode) z), '{}'::jsonb))
  into v_flow
  from billing.payment p
  join billing.billing_account a on a.id = p.account_id and a.tenant_id = p.tenant_id
  join billing.payment_tender t on t.payment_id = p.id and not t.is_deleted
  where p.tenant_id = p_tenant_id and not p.is_deleted and a.branch_id = p_branch_id
    and identity.branch_local_date_v1(a.branch_id, p.received_at) = p_on;

  v_expected_total := v_cash_exp + coalesce((select sum(expected_paise) from billing.noncash_expected(p_tenant_id, p_branch_id, p_on)), 0);

  select jsonb_build_object('id', g.id, 'signedBy', g.signed_by, 'signedAt', g.signed_at, 'note', g.note,
           'cashVariancePaise', g.cash_variance_paise, 'otherVariancePaise', g.other_variance_paise,
           'changedSince', g.expected_total_paise <> v_expected_total)
  into v_signoff
  from billing.day_signoff g
  where g.tenant_id = p_tenant_id and g.branch_id = p_branch_id and g.business_date = p_on and not g.is_deleted;

  if exists (select 1 from jsonb_array_elements(v_sessions) x where x ->> 'status' in ('open', 'stale')) then
    v_blockers := v_blockers || '["open_sessions"]'::jsonb;
  end if;
  if exists (select 1 from jsonb_array_elements(v_methods) x
             where x ->> 'settledPaise' is null and (x ->> 'expectedPaise')::bigint <> 0) then
    v_blockers := v_blockers || '["unsettled_methods"]'::jsonb;
  end if;
  if exists (select 1 from jsonb_array_elements(v_methods) x where (x ->> 'stale')::boolean) then
    v_blockers := v_blockers || '["stale_settlements"]'::jsonb;
  end if;

  return jsonb_build_object(
    'branchId', p_branch_id, 'date', p_on,
    'cash', jsonb_build_object('expectedPaise', v_cash_exp, 'countedPaise', v_cash_cnt, 'variancePaise', v_cash_var),
    'sessions', v_sessions, 'methods', v_methods,
    'otherVariancePaise', v_other_var, 'expectedTotalPaise', v_expected_total,
    'advances', v_flow -> 'advances', 'refunds', v_flow -> 'refunds', 'credit', v_flow -> 'credit',
    'flowByMode', v_flow -> 'byMode',
    'signoff', v_signoff,
    'blockers', case when v_signoff is null then v_blockers else '[]'::jsonb end);
end;
$$;

-- Repair: drawers already left open from an earlier day become stale (no history is rewritten).
update billing.counter_session s set status = 'stale', stale_at = pg_catalog.now()
from billing.counter c
where c.id = s.counter_id and s.status = 'open' and not s.is_deleted
  and s.business_date < identity.branch_local_date_v1(c.branch_id, pg_catalog.now());

revoke all on function billing.retire_stale_sessions(uuid, uuid) from public, anon, authenticated;
grant execute on function billing.retire_stale_sessions(uuid, uuid) to hms_svc_billing, service_role;
