-- cross-schema: approved (bill_json reads identity.branch_bill_header_v, unchanged from the previous definition; read-only)
-- #166: bill payments list each tender (split shows as 'split' plus a tenders array) and the
--       amount applied to this bill; an advance also reports its remaining balance.
-- #168: collection efficiency counts bill payments only (advances reported separately), capped at 100%.
-- #167: count-based services (consultation, procedure, lab, imaging, package) take whole quantities.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.bill_json(p_bill_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_account billing.billing_account%rowtype;
  v_totals billing.bill_totals_v1%rowtype;
  v_due bigint;
  v_lines jsonb;
  v_discounts jsonb;
  v_payments jsonb;
  v_live_gstin text;
  v_legal text;
  v_branch_name text;
  v_branch_address text;
  v_gstin text;
  v_state text;
  v_pos text;
  v_name text;
  v_address text;
  v_cgst bigint;
  v_sgst bigint;
  v_igst bigint;
begin
  select * into v_bill from billing.bill where id = p_bill_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  select * into v_totals from billing.bill_totals_v1 where bill_id = p_bill_id;
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  select bp.gstin, bp.legal_name into v_live_gstin, v_legal
  from billing.branch_profile bp
  where bp.tenant_id = v_bill.tenant_id and bp.branch_id = v_account.branch_id and not bp.is_deleted;
  select h.name, h.address into v_branch_name, v_branch_address
  from identity.branch_bill_header_v1(v_bill.tenant_id, v_account.branch_id) h;
  v_gstin := coalesce(v_bill.supplier_gstin, v_live_gstin);
  v_state := coalesce(v_bill.supplier_state_code, left(v_gstin, 2));
  v_pos := coalesce(v_bill.pos_state_code, v_state);
  v_name := coalesce(v_bill.supplier_name, nullif(btrim(v_legal), ''), v_branch_name);
  v_address := coalesce(v_bill.supplier_address, v_branch_address);
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', l.id, 'lineNo', l.line_no, 'serviceItemId', l.service_item_id,
      'code', si.code, 'name', si.name, 'quantity', l.quantity,
      'unitPricePaise', l.unit_price_paise, 'taxRateBp', l.tax_rate_bp,
      'netPaise', billing.line_net(l.quantity, l.unit_price_paise),
      'taxPaise', billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
      'sacHsnCode', tc.sac_hsn_code,
      'practitionerId', l.practitioner_id,
      'note', l.note,
      'locked', billing.line_is_locked(l.id)
    ) || billing.tax_split(
      billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
      l.tax_rate_bp, v_state, v_pos)
    order by l.line_no), '[]'::jsonb),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'cgstPaise')::bigint), 0),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'sgstPaise')::bigint), 0),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'igstPaise')::bigint), 0)
  into v_lines, v_cgst, v_sgst, v_igst
  from billing.bill_line l
  join billing.service_item si on si.id = l.service_item_id
  left join billing.tax_code tc on tc.id = si.tax_code_id
  where l.bill_id = p_bill_id and not l.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'billLineId', d.bill_line_id, 'kind', d.kind, 'value', d.value,
    'reasonCode', d.reason_code, 'approvalId', d.approval_id
  )), '[]'::jsonb) into v_discounts
  from billing.discount d
  join billing.approval_request a on a.id = d.approval_id and a.status = 'approved' and not a.is_deleted
  where d.bill_id = p_bill_id and not d.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'receiptNo', p.receipt_no, 'amountPaise', p.amount_paise,
    'refundedPaise', coalesce((
      select sum(r.amount_paise) from billing.payment r
      where r.refund_of_payment_id = p.id and not r.is_deleted), 0),
    'kind', p.kind,
    'appliedPaise', coalesce((
      select sum(al.amount_paise) from billing.allocation al
      where al.payment_id = p.id and al.bill_id = p_bill_id and not al.is_deleted), 0),
    'advanceBalancePaise', case when p.kind = 'advance' then p.amount_paise
      - coalesce((select sum(al.amount_paise) from billing.allocation al
          where al.payment_id = p.id and not al.is_deleted), 0)
      - coalesce((select sum(r.amount_paise) from billing.payment r
          where r.refund_of_payment_id = p.id and not r.is_deleted), 0) end,
    'tenders', coalesce((
      select jsonb_agg(jsonb_build_object('mode', t.mode, 'amountPaise', t.amount_paise) order by t.amount_paise desc, t.mode)
      from billing.payment_tender t where t.payment_id = p.id and not t.is_deleted), '[]'::jsonb),
    'mode', (
      select case when count(*) > 1 then 'split' else min(t.mode) end
      from billing.payment_tender t
      where t.payment_id = p.id and not t.is_deleted)
  ) order by p.received_at), '[]'::jsonb) into v_payments
  from billing.payment p
  where p.kind <> 'refund' and not p.is_deleted
    and exists (
      select 1 from billing.allocation al
      where al.payment_id = p.id and al.bill_id = p_bill_id and not al.is_deleted);
  return jsonb_build_object(
    'id', v_bill.id, 'billNo', v_bill.bill_no, 'status', v_bill.status, 'billKind', v_bill.bill_kind,
    'payerType', v_bill.payer_type, 'accountId', v_bill.account_id, 'patientId', v_account.patient_id,
    'branchId', v_account.branch_id, 'reversesBillId', v_bill.reverses_bill_id,
    'lines', v_lines, 'discounts', v_discounts, 'payments', coalesce(v_payments, '[]'::jsonb),
    'netPaise', v_totals.net_paise, 'taxPaise', v_totals.tax_paise,
    'discountPaise', v_totals.discount_paise, 'exactPaise', v_totals.exact_paise,
    'roundOffPaise', v_totals.round_off_paise, 'totalPaise', v_totals.total_paise,
    'cgstPaise', coalesce(v_cgst, 0), 'sgstPaise', coalesce(v_sgst, 0), 'igstPaise', coalesce(v_igst, 0),
    'allocatedPaise', billing.allocated_paise(p_bill_id),
    'duePaise', coalesce(v_due, v_totals.total_paise),
    'placeOfSupplyState', v_pos,
    'supplier', jsonb_build_object(
      'gstin', v_gstin, 'stateCode', v_state, 'name', v_name, 'address', v_address));
end;
$$;

create or replace function billing.earnings_money(p_from date, p_to date, p_branch uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_money jsonb;
begin
  select jsonb_build_object(
    'gross', coalesce((select sum(b.total_paise) from pg_temp.earn_bill b
      where b.bill_kind <> 'credit_note' and b.bill_date between p_from and p_to
        and (p_branch is null or b.branch_id = p_branch)), 0),
    'bills', coalesce((select count(*) from pg_temp.earn_bill b
      where b.bill_kind <> 'credit_note' and b.bill_date between p_from and p_to
        and (p_branch is null or b.branch_id = p_branch)), 0),
    'discount', coalesce((select sum(b.discount_paise) from pg_temp.earn_bill b
      where b.bill_kind <> 'credit_note' and b.bill_date between p_from and p_to
        and (p_branch is null or b.branch_id = p_branch)), 0),
    'base', coalesce((select sum(b.net_paise + b.tax_paise) from pg_temp.earn_bill b
      where b.bill_kind <> 'credit_note' and b.bill_date between p_from and p_to
        and (p_branch is null or b.branch_id = p_branch)), 0),
    'cgst', coalesce((select sum(b.cgst_paise) from pg_temp.earn_bill b
      where b.bill_date between p_from and p_to and (p_branch is null or b.branch_id = p_branch)), 0),
    'sgst', coalesce((select sum(b.sgst_paise) from pg_temp.earn_bill b
      where b.bill_date between p_from and p_to and (p_branch is null or b.branch_id = p_branch)), 0),
    'igst', coalesce((select sum(b.igst_paise) from pg_temp.earn_bill b
      where b.bill_date between p_from and p_to and (p_branch is null or b.branch_id = p_branch)), 0),
    'visits', coalesce((select count(distinct (b.patient_id, b.branch_id, b.bill_date)) from pg_temp.earn_bill b
      where b.bill_kind <> 'credit_note' and b.bill_date between p_from and p_to
        and (p_branch is null or b.branch_id = p_branch)), 0),
    'doctors', coalesce((select count(distinct l.practitioner_id) from pg_temp.earn_line l
      where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
        and l.bill_date between p_from and p_to and (p_branch is null or l.branch_id = p_branch)), 0),
    'doctorRevenue', coalesce((select sum(l.net_paise + l.tax_paise) from pg_temp.earn_line l
      where l.bill_kind <> 'credit_note' and l.practitioner_id is not null
        and l.bill_date between p_from and p_to and (p_branch is null or l.branch_id = p_branch)), 0),
    'collected', coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
      where t.kind in ('payment', 'advance') and t.mode <> 'credit'
        and t.pay_date between p_from and p_to and (p_branch is null or t.branch_id = p_branch)), 0),
    'collectedOnBills', coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
      where t.kind = 'payment' and t.mode <> 'credit'
        and t.pay_date between p_from and p_to and (p_branch is null or t.branch_id = p_branch)), 0),
    'advances', coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
      where t.kind = 'advance' and t.mode <> 'credit'
        and t.pay_date between p_from and p_to and (p_branch is null or t.branch_id = p_branch)), 0),
    'refunds', coalesce((select sum(t.amount_paise) from pg_temp.earn_tender t
      where t.kind = 'refund' and t.mode <> 'credit'
        and t.pay_date between p_from and p_to and (p_branch is null or t.branch_id = p_branch)), 0))
    into v_money;
  return v_money;
end;
$$;

create or replace function billing.earnings_card(
  p_cur jsonb, p_prev jsonb, p_mom jsonb, p_pmom jsonb, p_yoy jsonb, p_outstanding bigint)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_gross bigint := (p_cur ->> 'gross')::bigint;
  v_collected bigint := (p_cur ->> 'collected')::bigint;
  v_refunds bigint := (p_cur ->> 'refunds')::bigint;
  v_bills bigint := (p_cur ->> 'bills')::bigint;
  v_visits bigint := (p_cur ->> 'visits')::bigint;
  v_doctors bigint := (p_cur ->> 'doctors')::bigint;
  v_base bigint := (p_cur ->> 'base')::bigint;
  v_avg numeric := case when v_bills = 0 then null else round(v_gross::numeric / v_bills) end;
  v_prev_avg numeric := case when (p_prev ->> 'bills')::bigint = 0 then null else round((p_prev ->> 'gross')::numeric / (p_prev ->> 'bills')::bigint) end;
  v_eff numeric := case when v_gross = 0 then null else least(100, round(coalesce((p_cur ->> 'collectedOnBills')::numeric, v_collected) / v_gross * 100, 1)) end;
  v_prev_eff numeric := case when (p_prev ->> 'gross')::bigint = 0 then null else least(100, round(coalesce((p_prev ->> 'collectedOnBills')::numeric, (p_prev ->> 'collected')::numeric) / (p_prev ->> 'gross')::numeric * 100, 1)) end;
  v_refund_rate numeric := case when v_gross = 0 then null else round(v_refunds::numeric / v_gross * 100, 1) end;
  v_prev_refund numeric := case when (p_prev ->> 'gross')::bigint = 0 then null else round((p_prev ->> 'refunds')::numeric / (p_prev ->> 'gross')::numeric * 100, 1) end;
  v_discount_rate numeric := case when v_base = 0 then null else round((p_cur ->> 'discount')::numeric / v_base * 100, 1) end;
  v_per_visit numeric := case when v_visits = 0 then null else round(v_gross::numeric / v_visits) end;
  v_per_doctor numeric := case when v_doctors = 0 then null else round((p_cur ->> 'doctorRevenue')::numeric / v_doctors) end;
  v_gross_move jsonb := billing.earnings_move(v_gross, (p_prev ->> 'gross')::numeric);
  v_mom jsonb := billing.earnings_move((p_mom ->> 'gross')::numeric, (p_pmom ->> 'gross')::numeric);
  v_yoy jsonb := billing.earnings_move(v_gross, (p_yoy ->> 'gross')::numeric);
begin
  return jsonb_build_object(
    'grossBilledPaise', v_gross,
    'collectedPaise', v_collected,
    'refundsPaise', v_refunds,
    'advancesPaise', coalesce((p_cur ->> 'advances')::bigint, 0),
    'netEarningsPaise', v_collected - v_refunds,
    'outstandingPaise', coalesce(p_outstanding, 0),
    'discountPaise', (p_cur ->> 'discount')::bigint,
    'cgstPaise', (p_cur ->> 'cgst')::bigint,
    'sgstPaise', (p_cur ->> 'sgst')::bigint,
    'igstPaise', (p_cur ->> 'igst')::bigint,
    'billCount', v_bills,
    'averageBillPaise', v_avg,
    'visitCount', v_visits,
    'doctorCount', v_doctors,
    'revenuePerVisitPaise', v_per_visit,
    'revenuePerDoctorPaise', v_per_doctor,
    'collectionEfficiencyPct', v_eff,
    'refundRatePct', v_refund_rate,
    'discountRatePct', v_discount_rate,
    'periodGrowthPct', v_gross_move -> 'pct',
    'momGrowthPct', v_mom -> 'pct',
    'yoyGrowthPct', v_yoy -> 'pct',
    'deltas', jsonb_build_object(
      'grossBilled', v_gross_move,
      'collected', billing.earnings_move(v_collected, (p_prev ->> 'collected')::numeric),
      'netEarnings', billing.earnings_move(v_collected - v_refunds, (p_prev ->> 'collected')::numeric - (p_prev ->> 'refunds')::numeric),
      'refunds', billing.earnings_move(v_refunds, (p_prev ->> 'refunds')::numeric),
      'billCount', billing.earnings_move(v_bills, (p_prev ->> 'bills')::numeric),
      'averageBill', billing.earnings_move(v_avg, v_prev_avg),
      'collectionEfficiency', billing.earnings_move(v_eff, v_prev_eff),
      'refundRate', billing.earnings_move(v_refund_rate, v_prev_refund),
      'mom', v_mom,
      'yoy', v_yoy));
end;
$$;

create or replace function billing.bill_line_whole_quantity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.quantity <> trunc(new.quantity) and exists (
    select 1 from billing.service_item si
    where si.id = new.service_item_id
      and si.category in ('consultation', 'procedure', 'lab', 'imaging', 'package')) then
    raise exception 'quantity must be a whole number for this service' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function billing.bill_line_whole_quantity() from public, anon, authenticated;

drop trigger if exists bill_line_whole_quantity on billing.bill_line;
create trigger bill_line_whole_quantity
  before insert or update of quantity, service_item_id on billing.bill_line
  for each row execute function billing.bill_line_whole_quantity();
