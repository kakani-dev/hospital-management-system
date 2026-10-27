-- #92: the earnings report (sales register, GSTR-1 and the GST summary CSV) labels a bill
-- UNREGISTERED when the bill has no supplier GSTIN snapshot (for example, bills finalized
-- before the branch GSTIN was set), while the bill document already falls back to the
-- branch's current GSTIN (billing.bill_document: coalesce(supplier_gstin, branch_profile.gstin)).
-- The report now uses the same rule: the bill's snapshot GSTIN, else the branch's GSTIN,
-- else UNREGISTERED. Only this one expression changes; the function body is otherwise a copy
-- of 20261025250300_billing_earnings.sql. CREATE OR REPLACE keeps the owner and grants.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.earnings_report(
  p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid, p_grain text, p_fy integer, p_quarter integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
  v_len integer;
  v_grain text;
  v_focus uuid := p_branch_id;
  v_prev_from date;
  v_prev_to date;
  v_mom_from date;
  v_mom_to date;
  v_pmom_from date;
  v_pmom_to date;
  v_yoy_from date;
  v_yoy_to date;
  v_span_from date;
  v_span_to date;
  v_utc_from timestamptz;
  v_utc_to timestamptz;
  v_due_to timestamptz;
  v_full_month boolean;
  v_vs text;
  v_tenant jsonb;
  v_focus_card jsonb;
  v_cur jsonb;
  v_prev jsonb;
  v_outstanding bigint;
  v_insights text[] := array[]::text[];
  v_move jsonb;
  v_branches jsonb;
  v_top_branch text;
  v_bottom_branch text;
  v_top_share numeric;
  v_branch_count integer;
  v_top_doctor text;
  v_bottom_doctor text;
  v_doctor_count integer;
  v_age jsonb;
  v_truncated boolean := false;
  r record;
begin
  -- Definer so a tenant-wide reader still sees bills, payments and lines of a soft-deleted
  -- branch. RLS on those tables follows current_branch_ids, which drops deleted branches.
  -- The owner would pass billing.bypass_acl(), so the JWT permission is checked directly.
  if p_tenant_id is null
     or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_fy is not null then
    if p_fy < 2000 or p_fy > 2100 then
      raise exception 'financial year must be between 2000 and 2100' using errcode = '22023';
    end if;
    if p_quarter is null then
      v_from := make_date(p_fy, 4, 1);
      v_to := make_date(p_fy + 1, 3, 31);
    elsif p_quarter = 1 then
      v_from := make_date(p_fy, 4, 1);
      v_to := make_date(p_fy, 6, 30);
    elsif p_quarter = 2 then
      v_from := make_date(p_fy, 7, 1);
      v_to := make_date(p_fy, 9, 30);
    elsif p_quarter = 3 then
      v_from := make_date(p_fy, 10, 1);
      v_to := make_date(p_fy, 12, 31);
    elsif p_quarter = 4 then
      v_from := make_date(p_fy + 1, 1, 1);
      v_to := make_date(p_fy + 1, 3, 31);
    else
      raise exception 'quarter must be 1, 2, 3 or 4' using errcode = '22023';
    end if;
  else
    if p_from is null or p_to is null then
      raise exception 'from and to are required' using errcode = '22023';
    end if;
    v_from := p_from;
    v_to := p_to;
  end if;
  if v_to < v_from then
    raise exception 'to is before from' using errcode = '22023';
  end if;
  if (v_to - v_from) > 399 then
    raise exception 'the period is longer than 400 days' using errcode = '22023';
  end if;

  v_len := (v_to - v_from) + 1;
  v_grain := lower(btrim(coalesce(p_grain, '')));
  if v_grain = '' then
    v_grain := case when v_len > 62 then 'month' when v_len > 14 then 'week' else 'day' end;
  elsif v_grain not in ('day', 'week', 'month') then
    raise exception 'grain must be day, week or month' using errcode = '22023';
  end if;

  -- Equal-length window immediately before `from` (inclusive). MoM is the calendar month of `to`.
  v_prev_to := v_from - 1;
  v_prev_from := v_prev_to - (v_to - v_from);
  v_mom_from := date_trunc('month', v_to)::date;
  v_mom_to := (v_mom_from + interval '1 month' - interval '1 day')::date;
  v_pmom_from := (v_mom_from - interval '1 month')::date;
  v_pmom_to := (v_mom_from - 1);
  v_yoy_from := (v_from - interval '1 year')::date;
  v_yoy_to := (v_to - interval '1 year')::date;
  v_span_from := least(v_from, v_prev_from, v_pmom_from, v_yoy_from);
  v_span_to := greatest(v_to, v_mom_to);
  -- ±2 days covers any IANA offset so the btree on timestamptz is usable, then the local date filters.
  v_utc_from := (v_span_from - 2)::timestamp at time zone 'UTC';
  v_utc_to := (v_span_to + 3)::timestamp at time zone 'UTC';
  v_due_to := (v_to + 3)::timestamp at time zone 'UTC';
  v_full_month := v_from = date_trunc('month', v_from)::date
    and v_to = (date_trunc('month', v_from) + interval '1 month' - interval '1 day')::date;
  v_vs := case when v_full_month then 'last month' else 'the previous period' end;

  drop table if exists pg_temp.earn_branch;
  drop table if exists pg_temp.earn_bill;
  drop table if exists pg_temp.earn_line;
  drop table if exists pg_temp.earn_tender;
  drop table if exists pg_temp.earn_due;
  create temporary table pg_temp.earn_branch (
    branch_id uuid primary key, name text, is_deleted boolean, zone text, gstin text) on commit drop;
  create temporary table pg_temp.earn_bill (
    bill_id uuid primary key, branch_id uuid, patient_id uuid, bill_date date, bill_kind text, bill_no text,
    payer_type text, gstin text, reverses_bill_id uuid, original_no text,
    net_paise bigint, tax_paise bigint, discount_paise bigint, total_paise bigint,
    cgst_paise bigint, sgst_paise bigint, igst_paise bigint) on commit drop;
  create temporary table pg_temp.earn_line (
    line_id uuid primary key, bill_id uuid, branch_id uuid, bill_date date, bill_kind text,
    practitioner_id uuid, service_item_id uuid, code text, service_name text, sac text, exempt boolean,
    qty numeric, net_paise bigint, tax_paise bigint, cgst_paise bigint, sgst_paise bigint, igst_paise bigint) on commit drop;
  create temporary table pg_temp.earn_tender (
    tender_id uuid primary key, branch_id uuid, pay_date date, kind text, mode text, amount_paise bigint,
    receipt_no text, credit_note_no text) on commit drop;
  create temporary table pg_temp.earn_due (
    bill_id uuid primary key, branch_id uuid, bill_date date, due_paise bigint) on commit drop;

  insert into pg_temp.earn_branch (branch_id, name, is_deleted, zone, gstin)
  select e.branch_id, e.name, e.is_deleted, identity.branch_time_zone_v1(e.branch_id),
         coalesce(nullif(btrim(p.gstin), ''), 'UNREGISTERED')
  from identity.earnings_branches_v1(p_tenant_id) e
  left join billing.branch_profile p
    on p.tenant_id = p_tenant_id and p.branch_id = e.branch_id and not p.is_deleted;

  if v_focus is not null and not exists (select 1 from pg_temp.earn_branch where branch_id = v_focus) then
    perform billing.assert_branch(p_tenant_id, v_focus);
    raise exception 'branch out of scope' using errcode = '42501';
  end if;

  insert into pg_temp.earn_bill (
    bill_id, branch_id, patient_id, bill_date, bill_kind, bill_no, payer_type, gstin, reverses_bill_id, original_no,
    net_paise, tax_paise, discount_paise, total_paise, cgst_paise, sgst_paise, igst_paise)
  select b.id, a.branch_id, a.patient_id, (b.finalized_at at time zone br.zone)::date,
         b.bill_kind, b.bill_no, b.payer_type,
         coalesce(nullif(btrim(b.supplier_gstin), ''), br.gstin),  -- br.gstin is already 'UNREGISTERED' when blank
         b.reverses_bill_id,
         (select ob.bill_no from billing.bill ob where ob.id = b.reverses_bill_id),
         t.net_paise, t.tax_paise, t.discount_paise, t.total_paise,
         coalesce(g.cgst, 0), coalesce(g.sgst, 0), coalesce(g.igst, 0)
  from billing.bill b
  join billing.billing_account a on a.id = b.account_id and a.tenant_id = b.tenant_id
  join pg_temp.earn_branch br on br.branch_id = a.branch_id
  join billing.bill_totals_v1 t on t.bill_id = b.id
  left join lateral (
    select sum((s.split ->> 'cgstPaise')::bigint),
           sum((s.split ->> 'sgstPaise')::bigint),
           sum((s.split ->> 'igstPaise')::bigint)
    from (
      select billing.tax_split(
               billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
               l.tax_rate_bp, b.supplier_state_code, b.pos_state_code) as split
      from billing.bill_line l
      where l.bill_id = b.id and not l.is_deleted
    ) s
  ) g(cgst, sgst, igst) on true
  where b.tenant_id = p_tenant_id
    and b.status = 'finalized'
    and not b.is_deleted
    and b.finalized_at >= v_utc_from
    and b.finalized_at < v_utc_to
    and (b.finalized_at at time zone br.zone)::date between v_span_from and v_span_to;

  insert into pg_temp.earn_line (
    line_id, bill_id, branch_id, bill_date, bill_kind, practitioner_id, service_item_id, code, service_name, sac, exempt,
    qty, net_paise, tax_paise, cgst_paise, sgst_paise, igst_paise)
  select l.id, b.bill_id, b.branch_id, b.bill_date, b.bill_kind, l.practitioner_id, l.service_item_id,
         si.code, si.name, tc.sac_hsn_code, coalesce(tc.is_exempt, false), l.quantity,
         billing.line_net(l.quantity, l.unit_price_paise),
         billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
         (s.split ->> 'cgstPaise')::bigint,
         (s.split ->> 'sgstPaise')::bigint,
         (s.split ->> 'igstPaise')::bigint
  from pg_temp.earn_bill b
  join billing.bill_line l on l.bill_id = b.bill_id and not l.is_deleted
  join billing.bill src on src.id = b.bill_id
  left join billing.service_item si on si.id = l.service_item_id
  left join billing.tax_code tc on tc.id = si.tax_code_id
  cross join lateral (
    select billing.tax_split(
      billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
      l.tax_rate_bp, src.supplier_state_code, src.pos_state_code) as split
  ) s;

  insert into pg_temp.earn_tender (tender_id, branch_id, pay_date, kind, mode, amount_paise, receipt_no, credit_note_no)
  select td.id, a.branch_id, (p.received_at at time zone br.zone)::date, p.kind, td.mode, td.amount_paise,
         p.receipt_no, cn.bill_no
  from billing.payment p
  join billing.billing_account a on a.id = p.account_id and a.tenant_id = p.tenant_id
  join pg_temp.earn_branch br on br.branch_id = a.branch_id
  join billing.payment_tender td on td.payment_id = p.id and not td.is_deleted
  left join billing.bill cn on cn.id = p.credit_note_id
  where p.tenant_id = p_tenant_id
    and not p.is_deleted
    and p.received_at >= v_utc_from
    and p.received_at < v_utc_to
    and (p.received_at at time zone br.zone)::date between v_span_from and v_span_to;

  insert into pg_temp.earn_due (bill_id, branch_id, bill_date, due_paise)
  select b.id, a.branch_id, (b.finalized_at at time zone br.zone)::date,
         (t.total_paise - coalesce(cr.credited_paise, 0) - coalesce(al.allocated_paise, 0))
  from billing.bill b
  join billing.billing_account a on a.id = b.account_id and a.tenant_id = b.tenant_id
  join pg_temp.earn_branch br on br.branch_id = a.branch_id
  join billing.bill_totals_v1 t on t.bill_id = b.id
  left join lateral (
    select sum(-ct.total_paise)::bigint as credited_paise
    from billing.bill cn
    join billing.bill_totals_v1 ct on ct.bill_id = cn.id
    where cn.reverses_bill_id = b.id and cn.bill_kind = 'credit_note' and cn.status = 'finalized' and not cn.is_deleted
  ) cr on true
  left join lateral (
    select sum(x.amount_paise)::bigint as allocated_paise
    from billing.allocation x
    where x.bill_id = b.id and not x.is_deleted
  ) al on true
  where b.tenant_id = p_tenant_id
    and b.status = 'finalized'
    and b.bill_kind <> 'credit_note'
    and not b.is_deleted
    and b.finalized_at < v_due_to
    and (b.finalized_at at time zone br.zone)::date <= v_to
    and (t.total_paise - coalesce(cr.credited_paise, 0) - coalesce(al.allocated_paise, 0)) > 0;

  v_cur := billing.earnings_money(v_from, v_to, null);
  v_outstanding := coalesce((select sum(due_paise) from pg_temp.earn_due), 0);
  v_tenant := billing.earnings_card(
    v_cur,
    billing.earnings_money(v_prev_from, v_prev_to, null),
    billing.earnings_money(v_mom_from, v_mom_to, null),
    billing.earnings_money(v_pmom_from, v_pmom_to, null),
    billing.earnings_money(v_yoy_from, v_yoy_to, null),
    v_outstanding);
  v_outstanding := coalesce((select sum(due_paise) from pg_temp.earn_due d where v_focus is null or d.branch_id = v_focus), 0);
  v_focus_card := billing.earnings_card(
    billing.earnings_money(v_from, v_to, v_focus),
    billing.earnings_money(v_prev_from, v_prev_to, v_focus),
    billing.earnings_money(v_mom_from, v_mom_to, v_focus),
    billing.earnings_money(v_pmom_from, v_pmom_to, v_focus),
    billing.earnings_money(v_yoy_from, v_yoy_to, v_focus),
    v_outstanding);

  if (v_focus_card ->> 'billCount')::bigint = 0 and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array['No bills in this period.'];
  end if;

  for r in
    select br.branch_id, br.name,
           (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'gross')::numeric as gross,
           (billing.earnings_money(v_prev_from, v_prev_to, br.branch_id) ->> 'gross')::numeric as previous
    from pg_temp.earn_branch br
    where v_focus is null or br.branch_id = v_focus
    order by br.name
  loop
    exit when coalesce(cardinality(v_insights), 0) >= 8;
    v_move := billing.earnings_move(r.gross, r.previous);
    if v_move ->> 'direction' = 'down' and (v_move ->> 'pct')::numeric <= -10 then
      v_insights := v_insights || array[format('%s revenue down %s%% vs %s', r.name, billing.earnings_pct_text((v_move ->> 'pct')::numeric), v_vs)];
    elsif v_move ->> 'direction' = 'up' and (v_move ->> 'pct')::numeric >= 10 then
      v_insights := v_insights || array[format('%s revenue up %s%% vs %s', r.name, billing.earnings_pct_text((v_move ->> 'pct')::numeric), v_vs)];
    elsif v_move ->> 'direction' = 'new' and r.gross > 0 then
      v_insights := v_insights || array[format('%s revenue is new vs %s', r.name, v_vs)];
    end if;
  end loop;

  v_move := v_focus_card -> 'deltas' -> 'yoy';
  if v_move ->> 'direction' in ('up', 'down') and abs((v_move ->> 'pct')::numeric) >= 10
     and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array[format('Revenue %s %s%% vs the same dates last year',
      case when v_move ->> 'direction' = 'down' then 'down' else 'up' end,
      billing.earnings_pct_text((v_move ->> 'pct')::numeric))];
  end if;
  v_move := v_focus_card -> 'deltas' -> 'mom';
  if not v_full_month and v_move ->> 'direction' in ('up', 'down') and abs((v_move ->> 'pct')::numeric) >= 10
     and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array[format('Revenue %s %s%% vs the previous calendar month',
      case when v_move ->> 'direction' = 'down' then 'down' else 'up' end,
      billing.earnings_pct_text((v_move ->> 'pct')::numeric))];
  end if;
  if (v_focus_card ->> 'collectionEfficiencyPct') is not null and coalesce(cardinality(v_insights), 0) < 8 then
    if (v_focus_card ->> 'collectionEfficiencyPct')::numeric < 80 then
      v_insights := v_insights || array[format('Collection efficiency is %s%%', billing.earnings_pct_text((v_focus_card ->> 'collectionEfficiencyPct')::numeric))];
    elsif (v_focus_card ->> 'collectionEfficiencyPct')::numeric >= 98 then
      v_insights := v_insights || array[format('Collection efficiency is %s%%', billing.earnings_pct_text((v_focus_card ->> 'collectionEfficiencyPct')::numeric))];
    end if;
  end if;
  if v_outstanding > 0 and coalesce(cardinality(v_insights), 0) < 8 then
    select round(sum(due_paise) filter (where (v_to - bill_date) > 90)::numeric / sum(due_paise) * 100, 1)
      into v_top_share
    from pg_temp.earn_due
    where v_focus is null or branch_id = v_focus;
    if v_top_share >= 25 then
      v_insights := v_insights || array[format('%s%% of outstanding is older than 90 days', billing.earnings_pct_text(v_top_share))];
    end if;
  end if;
  if (v_focus_card ->> 'refundRatePct') is not null and (v_focus_card ->> 'refundRatePct')::numeric >= 5
     and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array[format('Refund rate is %s%%', billing.earnings_pct_text((v_focus_card ->> 'refundRatePct')::numeric))];
  end if;
  if (v_focus_card ->> 'discountRatePct') is not null and (v_focus_card ->> 'discountRatePct')::numeric >= 10
     and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array[format('Discount rate is %s%%', billing.earnings_pct_text((v_focus_card ->> 'discountRatePct')::numeric))];
  end if;

  with money as (
    select br.branch_id, br.name, br.gstin, br.is_deleted,
           (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'gross')::bigint as gross,
           (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'collected')::bigint as collected,
           (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'refunds')::bigint as refunds,
           (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'bills')::bigint as bills,
           billing.earnings_move(
             (billing.earnings_money(v_from, v_to, br.branch_id) ->> 'gross')::numeric,
             (billing.earnings_money(v_prev_from, v_prev_to, br.branch_id) ->> 'gross')::numeric) as move,
           coalesce((select sum(d.due_paise) from pg_temp.earn_due d where d.branch_id = br.branch_id), 0) as outstanding
    from pg_temp.earn_branch br
  ), ranked as (
    select m.*, row_number() over (order by m.gross desc, m.name asc) as rank,
           case when (v_cur ->> 'gross')::bigint = 0 then 0
                else round(m.gross::numeric / (v_cur ->> 'gross')::numeric * 100, 1) end as share
    from money m
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'branchId', branch_id, 'name', name, 'gstin', gstin, 'deleted', is_deleted,
           'rank', rank, 'sharePct', share, 'grossBilledPaise', gross, 'collectedPaise', collected,
           'netEarningsPaise', collected - refunds, 'outstandingPaise', outstanding, 'billCount', bills,
           'periodGrowthPct', move -> 'pct', 'direction', move ->> 'direction') order by rank), '[]'::jsonb),
         count(*),
         (array_agg(name order by rank))[1],
         (array_agg(share order by rank))[1],
         case when count(*) >= 2 then (array_agg(name order by rank desc))[1] else null end
    into v_branches, v_branch_count, v_top_branch, v_top_share, v_bottom_branch
  from ranked;

  if v_branch_count > 1 and v_top_share >= 50 and coalesce(cardinality(v_insights), 0) < 8 then
    v_insights := v_insights || array[format('%s is %s%% of hospital revenue', v_top_branch, billing.earnings_pct_text(v_top_share))];
  end if;

  select count(*) into v_doctor_count
  from (
    select l.practitioner_id
    from pg_temp.earn_line l
    where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
      and l.bill_date between v_from and v_to and (v_focus is null or l.branch_id = v_focus)
    group by l.practitioner_id
  ) d;
  if v_doctor_count >= 2 then
    select name into v_top_doctor from (
      select coalesce(appointment.practitioner_label_v1(p_tenant_id, l.practitioner_id), 'Unknown') as name,
             sum(l.net_paise + l.tax_paise) as revenue
      from pg_temp.earn_line l
      where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
        and l.bill_date between v_from and v_to and (v_focus is null or l.branch_id = v_focus)
      group by l.practitioner_id
      order by revenue desc, name asc
      limit 1) t;
    select name into v_bottom_doctor from (
      select coalesce(appointment.practitioner_label_v1(p_tenant_id, l.practitioner_id), 'Unknown') as name,
             sum(l.net_paise + l.tax_paise) as revenue
      from pg_temp.earn_line l
      where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
        and l.bill_date between v_from and v_to and (v_focus is null or l.branch_id = v_focus)
      group by l.practitioner_id
      order by revenue asc, name asc
      limit 1) t;
    if v_top_doctor is distinct from v_bottom_doctor and coalesce(cardinality(v_insights), 0) < 8 then
      v_insights := v_insights || array[format('%s leads doctor revenue', v_top_doctor)];
    end if;
    if v_top_doctor is distinct from v_bottom_doctor and coalesce(cardinality(v_insights), 0) < 8 then
      v_insights := v_insights || array[format('%s has the lowest doctor revenue', v_bottom_doctor)];
    end if;
  end if;

  select jsonb_build_object(
    'b0To30Paise', coalesce(sum(due_paise) filter (where (v_to - bill_date) <= 30), 0),
    'b31To60Paise', coalesce(sum(due_paise) filter (where (v_to - bill_date) between 31 and 60), 0),
    'b61To90Paise', coalesce(sum(due_paise) filter (where (v_to - bill_date) between 61 and 90), 0),
    'b90PlusPaise', coalesce(sum(due_paise) filter (where (v_to - bill_date) > 90), 0))
  into v_age
  from pg_temp.earn_due
  where v_focus is null or branch_id = v_focus;

  v_truncated :=
    (select count(*) from pg_temp.earn_bill b where b.bill_kind <> 'credit_note' and b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)) > 500
    or (select count(*) from pg_temp.earn_bill b where b.bill_kind = 'credit_note' and b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)) > 500
    or (select count(*) from pg_temp.earn_tender t where t.kind = 'refund' and t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)) > 500
    or (select count(*) from pg_temp.earn_tender t where t.kind in ('payment', 'advance') and t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)) > 500;

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'grain', v_grain, 'branchId', v_focus,
    'financialYear', p_fy, 'quarter', p_quarter,
    'level', case when v_focus is null then 'tenant' else 'branch' end,
    'tenant', v_tenant, 'focus', v_focus_card, 'branches', v_branches,
    'insights', to_jsonb(v_insights), 'ageing', v_age, 'truncated', v_truncated,
    'topBottom', jsonb_build_object(
      'topBranch', case when v_branch_count >= 2 then v_top_branch else null end,
      'bottomBranch', case when v_branch_count >= 2 and v_bottom_branch is distinct from v_top_branch then v_bottom_branch else null end,
      'topDoctor', case when v_doctor_count >= 2 and v_top_doctor is distinct from v_bottom_doctor then v_top_doctor else null end,
      'bottomDoctor', case when v_doctor_count >= 2 and v_top_doctor is distinct from v_bottom_doctor then v_bottom_doctor else null end))
  || jsonb_build_object(
    'trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'bucket', s.bucket, 'grossBilledPaise', s.gross, 'collectedPaise', s.collected, 'netEarningsPaise', s.collected - s.refunds)
               order by s.bucket), '[]'::jsonb)
      from (
        select gs.bucket::date as bucket,
               coalesce(sum(b.total_paise) filter (where b.bill_kind <> 'credit_note'), 0) as gross,
               coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
                 where t.kind in ('payment', 'advance') and t.mode <> 'credit'
                   and (v_focus is null or t.branch_id = v_focus)
                   and case v_grain
                         when 'week' then date_trunc('week', t.pay_date)::date
                         when 'month' then date_trunc('month', t.pay_date)::date
                         else t.pay_date end = gs.bucket::date), 0) as collected,
               coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
                 where t.kind = 'refund' and t.mode <> 'credit'
                   and (v_focus is null or t.branch_id = v_focus)
                   and case v_grain
                         when 'week' then date_trunc('week', t.pay_date)::date
                         when 'month' then date_trunc('month', t.pay_date)::date
                         else t.pay_date end = gs.bucket::date), 0) as refunds
        from generate_series(
          case v_grain when 'week' then date_trunc('week', v_from)::date when 'month' then date_trunc('month', v_from)::date else v_from end,
          case v_grain when 'week' then date_trunc('week', v_to)::date when 'month' then date_trunc('month', v_to)::date else v_to end,
          case v_grain when 'week' then interval '1 week' when 'month' then interval '1 month' else interval '1 day' end) as gs(bucket)
        left join pg_temp.earn_bill b
          on (v_focus is null or b.branch_id = v_focus)
         and b.bill_date between v_from and v_to
         and case v_grain
               when 'week' then date_trunc('week', b.bill_date)::date
               when 'month' then date_trunc('month', b.bill_date)::date
               else b.bill_date end = gs.bucket::date
        group by gs.bucket
      ) s),
    'doctors', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'practitionerId', d.practitioner_id, 'name', d.name, 'rank', d.rank,
               'revenuePaise', d.revenue, 'visits', d.visits) order by d.rank), '[]'::jsonb)
      from (
        select l.practitioner_id,
               coalesce(appointment.practitioner_label_v1(p_tenant_id, l.practitioner_id), 'Unknown') as name,
               sum(l.net_paise + l.tax_paise) as revenue,
               count(distinct (b.patient_id, b.branch_id, b.bill_date)) as visits,
               row_number() over (order by sum(l.net_paise + l.tax_paise) desc, coalesce(appointment.practitioner_label_v1(p_tenant_id, l.practitioner_id), 'Unknown')) as rank
        from pg_temp.earn_line l
        join pg_temp.earn_bill b on b.bill_id = l.bill_id
        where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
          and l.bill_date between v_from and v_to and (v_focus is null or l.branch_id = v_focus)
        group by l.practitioner_id
        order by revenue desc, name
        limit 50
      ) d),
    'services', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'serviceItemId', s.service_item_id, 'name', s.service_name, 'code', s.code, 'sac', coalesce(s.sac, 'UNSPECIFIED'),
               'revenuePaise', s.revenue, 'sharePct', s.share) order by s.revenue desc), '[]'::jsonb)
      from (
        select l.service_item_id, l.service_name, l.code, l.sac, sum(l.net_paise + l.tax_paise) as revenue,
               case when sum(sum(l.net_paise + l.tax_paise)) over () = 0 then 0
                    else round(sum(l.net_paise + l.tax_paise)::numeric / sum(sum(l.net_paise + l.tax_paise)) over () * 100, 1) end as share
        from pg_temp.earn_line l
        where l.bill_kind <> 'credit_note' and l.bill_date between v_from and v_to
          and (v_focus is null or l.branch_id = v_focus)
        group by l.service_item_id, l.service_name, l.code, l.sac
        order by revenue desc
        limit 50
      ) s),
    'paymentModes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'mode', m.mode, 'collectedPaise', m.collected, 'refundsPaise', m.refunds, 'sharePct', m.share) order by m.mode), '[]'::jsonb)
      from (
        select t.mode,
               coalesce(sum(t.amount_paise) filter (where t.kind in ('payment', 'advance')), 0) as collected,
               coalesce(sum(t.amount_paise) filter (where t.kind = 'refund'), 0) as refunds,
               case when sum(sum(t.amount_paise) filter (where t.kind in ('payment', 'advance'))) over () = 0 then 0
                    else round(coalesce(sum(t.amount_paise) filter (where t.kind in ('payment', 'advance')), 0)::numeric
                         / sum(sum(t.amount_paise) filter (where t.kind in ('payment', 'advance'))) over () * 100, 1) end as share
        from pg_temp.earn_tender t
        where t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)
        group by t.mode
      ) m),
    'gstr1', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'gstin', g.gstin, 'month', g.month,
               'b2cTaxablePaise', g.b2c_taxable, 'b2cCgstPaise', g.b2c_cgst, 'b2cSgstPaise', g.b2c_sgst, 'b2cIgstPaise', g.b2c_igst, 'b2cInvoices', g.b2c_n,
               'b2bTaxablePaise', g.b2b_taxable, 'b2bCgstPaise', g.b2b_cgst, 'b2bSgstPaise', g.b2b_sgst, 'b2bIgstPaise', g.b2b_igst, 'b2bInvoices', g.b2b_n,
               'creditNoteTaxablePaise', g.cn_taxable, 'creditNoteCgstPaise', g.cn_cgst, 'creditNoteSgstPaise', g.cn_sgst, 'creditNoteIgstPaise', g.cn_igst, 'creditNoteCount', g.cn_n)
               order by g.month, g.gstin), '[]'::jsonb)
      from (
        select b.gstin, to_char(b.bill_date, 'YYYY-MM') as month,
               coalesce(sum(b.net_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type = 'self'), 0) as b2c_taxable,
               coalesce(sum(b.cgst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type = 'self'), 0) as b2c_cgst,
               coalesce(sum(b.sgst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type = 'self'), 0) as b2c_sgst,
               coalesce(sum(b.igst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type = 'self'), 0) as b2c_igst,
               count(*) filter (where b.bill_kind <> 'credit_note' and b.payer_type = 'self') as b2c_n,
               coalesce(sum(b.net_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type <> 'self'), 0) as b2b_taxable,
               coalesce(sum(b.cgst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type <> 'self'), 0) as b2b_cgst,
               coalesce(sum(b.sgst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type <> 'self'), 0) as b2b_sgst,
               coalesce(sum(b.igst_paise) filter (where b.bill_kind <> 'credit_note' and b.payer_type <> 'self'), 0) as b2b_igst,
               count(*) filter (where b.bill_kind <> 'credit_note' and b.payer_type <> 'self') as b2b_n,
               coalesce(sum(-b.net_paise) filter (where b.bill_kind = 'credit_note'), 0) as cn_taxable,
               coalesce(sum(-b.cgst_paise) filter (where b.bill_kind = 'credit_note'), 0) as cn_cgst,
               coalesce(sum(-b.sgst_paise) filter (where b.bill_kind = 'credit_note'), 0) as cn_sgst,
               coalesce(sum(-b.igst_paise) filter (where b.bill_kind = 'credit_note'), 0) as cn_igst,
               count(*) filter (where b.bill_kind = 'credit_note') as cn_n
        from pg_temp.earn_bill b
        where b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)
        group by b.gstin, to_char(b.bill_date, 'YYYY-MM')
      ) g),
    'gstr3b', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'gstin', g.gstin, 'month', g.month,
               'outwardTaxablePaise', g.outward_taxable, 'exemptOutwardPaise', g.exempt_outward,
               'cgstPaise', g.cgst, 'sgstPaise', g.sgst, 'igstPaise', g.igst,
               'creditTaxablePaise', g.credit_taxable, 'creditCgstPaise', g.credit_cgst, 'creditSgstPaise', g.credit_sgst, 'creditIgstPaise', g.credit_igst,
               'netCgstPaise', g.net_cgst, 'netSgstPaise', g.net_sgst, 'netIgstPaise', g.net_igst)
               order by g.month, g.gstin), '[]'::jsonb)
      from (
        select b.gstin, to_char(b.bill_date, 'YYYY-MM') as month,
               coalesce(sum(l.net_paise) filter (where b.bill_kind <> 'credit_note' and not l.exempt), 0) as outward_taxable,
               coalesce(sum(l.net_paise) filter (where b.bill_kind <> 'credit_note' and l.exempt), 0) as exempt_outward,
               coalesce(sum(l.cgst_paise) filter (where b.bill_kind <> 'credit_note'), 0) as cgst,
               coalesce(sum(l.sgst_paise) filter (where b.bill_kind <> 'credit_note'), 0) as sgst,
               coalesce(sum(l.igst_paise) filter (where b.bill_kind <> 'credit_note'), 0) as igst,
               coalesce(sum(-l.net_paise) filter (where b.bill_kind = 'credit_note'), 0) as credit_taxable,
               coalesce(sum(-l.cgst_paise) filter (where b.bill_kind = 'credit_note'), 0) as credit_cgst,
               coalesce(sum(-l.sgst_paise) filter (where b.bill_kind = 'credit_note'), 0) as credit_sgst,
               coalesce(sum(-l.igst_paise) filter (where b.bill_kind = 'credit_note'), 0) as credit_igst,
               coalesce(sum(l.cgst_paise), 0) as net_cgst,
               coalesce(sum(l.sgst_paise), 0) as net_sgst,
               coalesce(sum(l.igst_paise), 0) as net_igst
        from pg_temp.earn_line l
        join pg_temp.earn_bill b on b.bill_id = l.bill_id
        where b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)
        group by b.gstin, to_char(b.bill_date, 'YYYY-MM')
      ) g),
    'hsn', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'sac', h.sac, 'taxablePaise', h.taxable, 'cgstPaise', h.cgst, 'sgstPaise', h.sgst, 'igstPaise', h.igst, 'quantity', h.qty)
               order by h.sac), '[]'::jsonb)
      from (
        select coalesce(nullif(btrim(l.sac), ''), 'UNSPECIFIED') as sac,
               sum(l.net_paise) as taxable, sum(l.cgst_paise) as cgst, sum(l.sgst_paise) as sgst, sum(l.igst_paise) as igst, sum(l.qty) as qty
        from pg_temp.earn_line l
        where l.bill_date between v_from and v_to and (v_focus is null or l.branch_id = v_focus)
        group by 1
      ) h),
    'sales', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'invoiceNumber', s.bill_no, 'date', s.bill_date,
               'party', coalesce(patient.party_label_v1(p_tenant_id, s.patient_id), 'Unknown'),
               'supply', case when s.payer_type = 'self' then 'B2C' else 'B2B' end,
               'gstin', s.gstin, 'taxablePaise', s.net_paise, 'cgstPaise', s.cgst_paise, 'sgstPaise', s.sgst_paise,
               'igstPaise', s.igst_paise, 'taxPaise', s.tax_paise, 'totalPaise', s.total_paise) order by s.bill_date, s.bill_no), '[]'::jsonb)
      from (
        select * from pg_temp.earn_bill b
        where b.bill_kind <> 'credit_note' and b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)
        order by b.bill_date, b.bill_no
        limit 500
      ) s),
    'creditNotes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'creditNoteNumber', s.bill_no, 'date', s.bill_date, 'originalInvoice', s.original_no,
               'party', coalesce(patient.party_label_v1(p_tenant_id, s.patient_id), 'Unknown'),
               'gstin', s.gstin, 'taxablePaise', -s.net_paise, 'taxPaise', -s.tax_paise, 'totalPaise', -s.total_paise)
               order by s.bill_date, s.bill_no), '[]'::jsonb)
      from (
        select * from pg_temp.earn_bill b
        where b.bill_kind = 'credit_note' and b.bill_date between v_from and v_to and (v_focus is null or b.branch_id = v_focus)
        order by b.bill_date, b.bill_no
        limit 500
      ) s),
    'refunds', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'receiptNumber', t.receipt_no, 'date', t.pay_date, 'mode', t.mode, 'amountPaise', t.amount_paise,
               'creditNoteNumber', t.credit_note_no) order by t.pay_date, t.receipt_no), '[]'::jsonb)
      from (
        select * from pg_temp.earn_tender t
        where t.kind = 'refund' and t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)
        order by t.pay_date, t.receipt_no
        limit 500
      ) t),
    'receipts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'receiptNumber', t.receipt_no, 'date', t.pay_date, 'mode', t.mode, 'kind', t.kind, 'amountPaise', t.amount_paise)
               order by t.pay_date, t.receipt_no), '[]'::jsonb)
      from (
        select * from pg_temp.earn_tender t
        where t.kind in ('payment', 'advance') and t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)
        order by t.pay_date, t.receipt_no
        limit 500
      ) t),
    'dayEndCash', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'date', c.pay_date, 'cashInPaise', c.cash_in, 'cashOutPaise', c.cash_out, 'netCashPaise', c.cash_in - c.cash_out,
               'cardPaise', c.card_net, 'upiPaise', c.upi_net, 'bankPaise', c.bank_net) order by c.pay_date), '[]'::jsonb)
      from (
        select t.pay_date,
               coalesce(sum(t.amount_paise) filter (where t.mode = 'cash' and t.kind in ('payment', 'advance')), 0) as cash_in,
               coalesce(sum(t.amount_paise) filter (where t.mode = 'cash' and t.kind = 'refund'), 0) as cash_out,
               coalesce(sum(case when t.mode = 'card' and t.kind = 'refund' then -t.amount_paise when t.mode = 'card' then t.amount_paise else 0 end), 0) as card_net,
               coalesce(sum(case when t.mode = 'upi' and t.kind = 'refund' then -t.amount_paise when t.mode = 'upi' then t.amount_paise else 0 end), 0) as upi_net,
               coalesce(sum(case when t.mode = 'bank' and t.kind = 'refund' then -t.amount_paise when t.mode = 'bank' then t.amount_paise else 0 end), 0) as bank_net
        from pg_temp.earn_tender t
        where t.pay_date between v_from and v_to and (v_focus is null or t.branch_id = v_focus)
          and t.mode in ('cash', 'card', 'upi', 'bank')
        group by t.pay_date
      ) c))
  ;
end;
$$;

revoke all on function billing.earnings_report(uuid, date, date, uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function billing.earnings_report(uuid, date, date, uuid, text, integer, integer) to hms_svc_billing;
