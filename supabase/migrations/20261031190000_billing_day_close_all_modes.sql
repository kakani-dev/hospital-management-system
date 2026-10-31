-- cross-schema: approved (audit.* triggers, identity.current_tenant_ids()/current_branch_ids() in RLS, identity.has_tenant_permission via billing.assert_permission and the published identity.branch_local_date_v1 read)
-- #65: day-end close beyond cash. Per method (cash per drawer; card / UPI / bank incl. cheque per
-- payment account for the branch-day) expected vs counted/settled, variance with a reason, cash
-- shift handover acknowledged by the incoming cashier, and a supervisor sign-off per branch-day that
-- locks the day (maker-checker; cash variance within the tenant's cash_variance approval policy).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table billing.counter_close
  add column expected_paise bigint,
  add column variance_reason text,
  add constraint counter_close_reason check (variance_reason is null or char_length(variance_reason) between 1 and 200);

create table billing.cash_handover (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references identity.tenants (id) on delete restrict,
  branch_id         uuid not null,
  from_session_id   uuid not null references billing.counter_session (id) on delete restrict,
  amount_paise      bigint not null,
  note              text,
  received_by       uuid,
  received_at       timestamptz,
  to_session_id     uuid references billing.counter_session (id) on delete restrict,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint cash_handover_amount check (amount_paise > 0),
  constraint cash_handover_note check (note is null or char_length(note) <= 200)
);
create unique index cash_handover_from on billing.cash_handover (from_session_id) where not is_deleted;
create index cash_handover_branch on billing.cash_handover (tenant_id, branch_id, created_on desc);
comment on table billing.cash_handover is '#65: cash left in the drawer at shift end, acknowledged by the incoming cashier (becomes their float).';

create table billing.day_settlement (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references identity.tenants (id) on delete restrict,
  branch_id           uuid not null,
  business_date       date not null,
  mode                text not null,
  payment_account_id  uuid,
  expected_paise      bigint not null,
  settled_paise       bigint not null,
  reason              text,
  recorded_by         uuid not null,
  created_on          timestamptz not null default now(),
  created_by          uuid not null,
  updated_on          timestamptz not null default now(),
  updated_by          uuid not null,
  is_deleted          boolean not null default false,
  constraint day_settlement_mode check (mode in ('card', 'upi', 'bank')),
  constraint day_settlement_settled check (settled_paise >= 0),
  constraint day_settlement_reason check (reason is null or char_length(reason) between 1 and 200)
);
create unique index day_settlement_key on billing.day_settlement
  (tenant_id, branch_id, business_date, mode, coalesce(payment_account_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where not is_deleted;
comment on table billing.day_settlement is '#65: settled amount per non-cash method/account for a branch-day (EDC batch, UPI/bank statement, cheques deposited) with the expected at entry.';

create table billing.day_signoff (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references identity.tenants (id) on delete restrict,
  branch_id             uuid not null,
  business_date         date not null,
  signed_by             uuid not null,
  signed_at             timestamptz not null default now(),
  note                  text,
  cash_variance_paise   bigint not null,
  other_variance_paise  bigint not null,
  expected_total_paise  bigint not null,
  snapshot              jsonb not null,
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint day_signoff_note check (note is null or char_length(note) <= 500)
);
create unique index day_signoff_key on billing.day_signoff (tenant_id, branch_id, business_date) where not is_deleted;
comment on table billing.day_signoff is '#65: supervisor sign-off of a branch-day; locks closes, handovers and settlements for that day.';

create trigger cash_handover_audit_columns before insert or update on billing.cash_handover
  for each row execute function audit.stamp_audit_columns();
create trigger cash_handover_tenant_immutable before update on billing.cash_handover
  for each row execute function audit.prevent_tenant_change();
create trigger cash_handover_audit_log after insert or update or delete on billing.cash_handover
  for each row execute function audit.log_row_change();
create trigger day_settlement_audit_columns before insert or update on billing.day_settlement
  for each row execute function audit.stamp_audit_columns();
create trigger day_settlement_tenant_immutable before update on billing.day_settlement
  for each row execute function audit.prevent_tenant_change();
create trigger day_settlement_audit_log after insert or update or delete on billing.day_settlement
  for each row execute function audit.log_row_change();
create trigger day_signoff_audit_columns before insert or update on billing.day_signoff
  for each row execute function audit.stamp_audit_columns();
create trigger day_signoff_tenant_immutable before update on billing.day_signoff
  for each row execute function audit.prevent_tenant_change();
create trigger day_signoff_audit_log after insert or update or delete on billing.day_signoff
  for each row execute function audit.log_row_change();

alter table billing.cash_handover enable row level security;
alter table billing.day_settlement enable row level security;
alter table billing.day_signoff enable row level security;
revoke all on billing.cash_handover, billing.day_settlement, billing.day_signoff from anon, authenticated, public;
grant select, insert, update on billing.cash_handover, billing.day_settlement to hms_svc_billing;
grant select, insert on billing.day_signoff to hms_svc_billing;
grant all on billing.cash_handover, billing.day_settlement, billing.day_signoff to service_role;
create policy cash_handover_branch on billing.cash_handover for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)));
create policy day_settlement_branch on billing.day_settlement for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)));
create policy day_signoff_branch on billing.day_signoff for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids()) and branch_id in (select identity.current_branch_ids(tenant_id)));

-- ------------------------------------------------------------------ helpers ----
create or replace function billing.assert_day_open(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if exists (select 1 from billing.day_signoff
             where tenant_id = p_tenant_id and branch_id = p_branch_id and business_date = p_on and not is_deleted) then
    raise exception 'this day is already signed off' using errcode = '55000';
  end if;
end;
$$;

create or replace function billing.clean_reason(p_reason text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '')
$$;

-- Non-cash expected per mode/account for a branch-day (receipts and advances minus refunds).
create or replace function billing.noncash_expected(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns table (mode text, payment_account_id uuid, label text, received_paise bigint, refunded_paise bigint, expected_paise bigint, n bigint)
language sql
stable
set search_path = ''
as $$
  select x ->> 'mode', nullif(x ->> 'paymentAccountId', '')::uuid, x ->> 'label',
         (x ->> 'receivedPaise')::bigint, (x ->> 'refundedPaise')::bigint, (x ->> 'netPaise')::bigint, (x ->> 'count')::bigint
  from jsonb_array_elements(billing.account_totals(p_tenant_id, p_branch_id, p_on, p_on)) x
  where x ->> 'mode' in ('card', 'upi', 'bank')
$$;

-- ------------------------------------------------------------------ summary ----
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

  if exists (select 1 from jsonb_array_elements(v_sessions) x where x ->> 'status' = 'open') then
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

-- ------------------------------------------------------------------ cash close + handover ----
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
  if v_session.status <> 'open' then
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

create or replace function billing.receive_handover(p_tenant_id uuid, p_handover_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_h billing.cash_handover%rowtype;
  v_from uuid;
  v_day date;
  v_doc jsonb;
  v_to uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_h from billing.cash_handover
  where id = p_handover_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_h.id is null then
    raise exception 'handover not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_h.branch_id);
  if v_h.received_by is not null then
    raise exception 'this handover was already received' using errcode = '55000';
  end if;
  select cashier_id, business_date into v_from, v_day from billing.counter_session where id = v_h.from_session_id;
  if v_from is not distinct from audit.session_actor_id() then
    raise exception 'the incoming cashier must receive the handover' using errcode = '42501';
  end if;
  perform billing.assert_day_open(p_tenant_id, v_h.branch_id, v_day);
  v_doc := billing.ensure_cashier_session(p_tenant_id, v_h.branch_id);
  v_to := (v_doc ->> 'id')::uuid;
  update billing.counter_session set opening_float_paise = opening_float_paise + v_h.amount_paise
  where id = v_to and status = 'open';
  update billing.cash_handover
  set received_by = audit.session_actor_id(), received_at = pg_catalog.now(), to_session_id = v_to
  where id = p_handover_id;
  return jsonb_build_object('handoverId', p_handover_id, 'toSessionId', v_to, 'amountPaise', v_h.amount_paise);
end;
$$;

-- ------------------------------------------------------------------ non-cash settlement ----
create or replace function billing.record_settlements(p_tenant_id uuid, p_branch_id uuid, p_on date, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_item jsonb;
  v_mode text;
  v_account uuid;
  v_settled bigint;
  v_expected bigint;
  v_reason text;
  v_id uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  perform billing.assert_day_open(p_tenant_id, p_branch_id, p_on);
  if jsonb_typeof(p_body -> 'items') <> 'array' or jsonb_array_length(p_body -> 'items') = 0 then
    raise exception 'items are required' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(p_body -> 'items') loop
    v_mode := v_item ->> 'mode';
    if v_mode not in ('card', 'upi', 'bank') then
      raise exception 'mode must be card, upi or bank' using errcode = '22023';
    end if;
    v_account := nullif(v_item ->> 'paymentAccountId', '')::uuid;
    if jsonb_typeof(v_item -> 'settledPaise') <> 'number' or (v_item ->> 'settledPaise')::bigint < 0 then
      raise exception 'settledPaise must be zero or more' using errcode = '22023';
    end if;
    v_settled := (v_item ->> 'settledPaise')::bigint;
    v_reason := billing.clean_reason(v_item ->> 'reason');
    if char_length(coalesce(v_reason, '')) > 200 then
      raise exception 'reason must be 200 characters or fewer' using errcode = '22023';
    end if;
    select coalesce(sum(e.expected_paise), 0) into v_expected
    from billing.noncash_expected(p_tenant_id, p_branch_id, p_on) e
    where e.mode = v_mode and e.payment_account_id is not distinct from v_account;
    if v_settled <> v_expected and v_reason is null then
      raise exception 'a reason is required when settled differs from expected' using errcode = '22023';
    end if;
    update billing.day_settlement
    set settled_paise = v_settled, expected_paise = v_expected,
        reason = case when v_settled <> v_expected then v_reason end, recorded_by = audit.session_actor_id()
    where tenant_id = p_tenant_id and branch_id = p_branch_id and business_date = p_on and not is_deleted
      and mode = v_mode and payment_account_id is not distinct from v_account
    returning id into v_id;
    if v_id is null then
      insert into billing.day_settlement (tenant_id, branch_id, business_date, mode, payment_account_id,
        expected_paise, settled_paise, reason, recorded_by)
      values (p_tenant_id, p_branch_id, p_on, v_mode, v_account, v_expected, v_settled,
        case when v_settled <> v_expected then v_reason end, audit.session_actor_id());
    end if;
    v_id := null;
  end loop;
  return billing.day_close_summary(p_tenant_id, p_branch_id, p_on);
end;
$$;

-- ------------------------------------------------------------------ sign-off ----
create or replace function billing.signoff_day(p_tenant_id uuid, p_branch_id uuid, p_on date, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor uuid := audit.session_actor_id();
  v_summary jsonb;
  v_cash_var bigint;
  v_abs bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.counter_reconcile');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('billing.signoff:' || p_branch_id::text || p_on::text));
  perform billing.assert_day_open(p_tenant_id, p_branch_id, p_on);
  if char_length(coalesce(p_body ->> 'note', '')) > 500 then
    raise exception 'note must be 500 characters or fewer' using errcode = '22023';
  end if;
  v_summary := billing.day_close_summary(p_tenant_id, p_branch_id, p_on);
  if v_summary -> 'blockers' ? 'open_sessions' then
    raise exception 'close every open drawer before signing off' using errcode = '55000';
  end if;
  if v_summary -> 'blockers' ? 'unsettled_methods' then
    raise exception 'enter the settled amount for every card, UPI and bank line first' using errcode = '55000';
  end if;
  if v_summary -> 'blockers' ? 'stale_settlements' then
    raise exception 'payments changed after a settlement was entered: re-enter it' using errcode = '55000';
  end if;
  if exists (select 1 from jsonb_array_elements(v_summary -> 'sessions') x
             where (x ->> 'variancePaise')::bigint <> 0 and (x ->> 'cashierId')::uuid is not distinct from v_actor)
     or exists (select 1 from billing.day_settlement d
                where d.tenant_id = p_tenant_id and d.branch_id = p_branch_id and d.business_date = p_on
                  and not d.is_deleted and d.settled_paise <> d.expected_paise and d.recorded_by is not distinct from v_actor) then
    raise exception 'You reported a variance today, so someone else must sign off.' using errcode = '42501';
  end if;
  select coalesce(sum(abs((x ->> 'variancePaise')::bigint)), 0) into v_abs
  from jsonb_array_elements(v_summary -> 'sessions') x where x ->> 'variancePaise' is not null;
  if v_abs > 0 and not billing.bypass_acl() and not billing.within_limit(p_tenant_id, 'cash_variance', v_abs, null) then
    raise exception 'cash variance is outside your approval limit' using errcode = '42501';
  end if;
  v_cash_var := (v_summary -> 'cash' ->> 'variancePaise')::bigint;
  insert into billing.day_signoff (tenant_id, branch_id, business_date, signed_by, note,
    cash_variance_paise, other_variance_paise, expected_total_paise, snapshot)
  values (p_tenant_id, p_branch_id, p_on, v_actor, billing.clean_reason(p_body ->> 'note'),
    v_cash_var, (v_summary ->> 'otherVariancePaise')::bigint, (v_summary ->> 'expectedTotalPaise')::bigint, v_summary);
  update billing.counter_session s set status = 'reconciled'
  from billing.counter c
  where c.id = s.counter_id and c.branch_id = p_branch_id
    and s.tenant_id = p_tenant_id and s.business_date = p_on and s.status = 'closed' and not s.is_deleted;
  return billing.day_close_summary(p_tenant_id, p_branch_id, p_on);
end;
$$;

revoke all on function billing.assert_day_open(uuid, uuid, date), billing.clean_reason(text),
  billing.noncash_expected(uuid, uuid, date), billing.day_close_summary(uuid, uuid, date),
  billing.close_counter_session(uuid, uuid, jsonb), billing.receive_handover(uuid, uuid),
  billing.record_settlements(uuid, uuid, date, jsonb), billing.signoff_day(uuid, uuid, date, jsonb)
  from public, anon, authenticated;
grant execute on function billing.assert_day_open(uuid, uuid, date), billing.clean_reason(text),
  billing.noncash_expected(uuid, uuid, date), billing.day_close_summary(uuid, uuid, date),
  billing.close_counter_session(uuid, uuid, jsonb), billing.receive_handover(uuid, uuid),
  billing.record_settlements(uuid, uuid, date, jsonb), billing.signoff_day(uuid, uuid, date, jsonb)
  to hms_svc_billing, service_role;
