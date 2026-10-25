-- BUG-47: day-end uses the same expected-cash figure as close_session
-- (opening float + cash receipts − cash refunds). Variance is counted − expected once cash is counted.
-- cross-schema: approved (close_session already stamps audit.session_actor_id)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.expected_cash_paise(p_session_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select s.opening_float_paise + coalesce((
    select sum(case when p.kind = 'refund' then -t.amount_paise else t.amount_paise end)
    from billing.payment p
    join billing.payment_tender t on t.payment_id = p.id and t.mode = 'cash' and not t.is_deleted
    where p.counter_session_id = s.id and not p.is_deleted
  ), 0)
  from billing.counter_session s
  where s.id = p_session_id and not s.is_deleted
$$;

revoke all on function billing.expected_cash_paise(uuid) from public, anon, authenticated;
grant execute on function billing.expected_cash_paise(uuid) to hms_svc_billing;

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
  if v_session.status <> 'open' then
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

create or replace function billing.day_end(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sessionId', s.id, 'counterId', s.counter_id, 'cashierId', s.cashier_id,
      'status', s.status, 'openingFloatPaise', s.opening_float_paise,
      'countedCashPaise', c.counted_paise,
      'expectedCashPaise', billing.expected_cash_paise(s.id),
      'variancePaise', case
        when c.counted_paise is null then null
        else c.counted_paise - billing.expected_cash_paise(s.id)
      end,
      'businessDate', s.business_date
    ) order by s.opened_at)
    from billing.counter_session s
    join billing.counter k on k.id = s.counter_id
    left join billing.counter_close c on c.counter_session_id = s.id and c.mode = 'cash' and not c.is_deleted
    where s.tenant_id = p_tenant_id and k.branch_id = p_branch_id and s.business_date = p_on and not s.is_deleted
  ), '[]'::jsonb);
end;
$$;
