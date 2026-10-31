-- cross-schema: approved (read-only owner KPIs; billing service reads appointment, patient and pharmacy facts for the caller's branches, as earnings_report does for billing)
-- Owner dashboard: daily KPIs for a date range (max 92 days) and branch (or all of the caller's
-- branches). Gated by billing.earnings (owner / admin / accountant / finance). Read-only.
-- OPD visits = non-cancelled queue tokens + checked-in appointments without a token.
-- Collections = payments and advances by tender mode; refunds separate. Billed = finalized bills
-- (credit notes reduce it); discounts from bill_totals_v1. Pharmacy sales = dispensed qty x batch MRP.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.owner_kpis(p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_branches uuid[];
  v_days jsonb;
  v_modes jsonb;
begin
  -- Security definer: billing.bypass_acl() would always be true here, so check the caller directly.
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'date range must be 1 to 92 days' using errcode = '22023';
  end if;
  if p_branch_id is not null and p_branch_id not in (select identity.current_branch_ids(p_tenant_id)) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;

  select coalesce(array_agg(b.id), '{}') into v_branches
  from identity.branches b
  where b.tenant_id = p_tenant_id
    and (p_branch_id is null or b.id = p_branch_id)
    and b.id in (select identity.current_branch_ids(p_tenant_id));

  with d as (select g::date as day from generate_series(p_from, p_to, interval '1 day') g),
  visits as (
    select q.queue_date as day, count(*) as n from appointment.queue_entries q
    where q.tenant_id = p_tenant_id and q.branch_id = any(v_branches) and q.status <> 'cancelled'
      and q.queue_date between p_from and p_to
    group by 1
    union all
    select identity.branch_local_date_v1(a.branch_id, a.starts_at), count(*) from appointment.appointments a
    where a.tenant_id = p_tenant_id and a.branch_id = any(v_branches)
      and a.status in ('checked_in', 'in_consultation', 'completed')
      and a.starts_at >= p_from::timestamptz - interval '1 day' and a.starts_at < p_to::timestamptz + interval '2 days'
      and not exists (select 1 from appointment.queue_entries q where q.appointment_id = a.id and q.tenant_id = p_tenant_id)
    group by 1),
  noshow as (
    select identity.branch_local_date_v1(a.branch_id, a.starts_at) as day, count(*) as n from appointment.appointments a
    where a.tenant_id = p_tenant_id and a.branch_id = any(v_branches) and a.status = 'no_show'
      and a.starts_at >= p_from::timestamptz - interval '1 day' and a.starts_at < p_to::timestamptz + interval '2 days'
    group by 1),
  pts as (
    select identity.branch_local_date_v1(p.registered_branch_id, p.created_at) as day, count(*) as n from patient.patients p
    where p.tenant_id = p_tenant_id and p.registered_branch_id = any(v_branches) and p.deleted_at is null
      and p.created_at >= p_from::timestamptz - interval '1 day' and p.created_at < p_to::timestamptz + interval '2 days'
    group by 1),
  bills as (
    select identity.branch_local_date_v1(ac.branch_id, b.finalized_at) as day,
           sum(t.total_paise) as billed, sum(t.discount_paise) filter (where b.bill_kind <> 'credit_note') as disc,
           -sum(t.total_paise) filter (where b.bill_kind = 'credit_note') as cn
    from billing.bill b
    join billing.billing_account ac on ac.id = b.account_id and ac.tenant_id = b.tenant_id
    join billing.bill_totals_v1 t on t.bill_id = b.id
    where b.tenant_id = p_tenant_id and not b.is_deleted and b.status = 'finalized' and ac.branch_id = any(v_branches)
      and b.finalized_at >= p_from::timestamptz - interval '1 day' and b.finalized_at < p_to::timestamptz + interval '2 days'
    group by 1),
  pays as (
    select identity.branch_local_date_v1(ac.branch_id, p.received_at) as day,
           sum(t.amount_paise) filter (where p.kind <> 'refund' and t.mode <> 'credit') as coll,
           sum(t.amount_paise) filter (where p.kind = 'refund') as refund
    from billing.payment p
    join billing.billing_account ac on ac.id = p.account_id and ac.tenant_id = p.tenant_id
    join billing.payment_tender t on t.payment_id = p.id and not t.is_deleted
    where p.tenant_id = p_tenant_id and not p.is_deleted and ac.branch_id = any(v_branches)
      and p.received_at >= p_from::timestamptz - interval '1 day' and p.received_at < p_to::timestamptz + interval '2 days'
    group by 1),
  rx as (
    select identity.branch_local_date_v1(x.branch_id, x.created_on) as day, count(distinct x.id) as n,
           sum(l.qty_base * bt.mrp_paise) as amt
    from pharmacy.dispense x
    join pharmacy.dispense_line l on l.dispense_id = x.id and l.tenant_id = x.tenant_id
    join inventory.batch bt on bt.id = l.batch_id
    where x.tenant_id = p_tenant_id and x.branch_id = any(v_branches)
      and x.created_on >= p_from::timestamptz - interval '1 day' and x.created_on < p_to::timestamptz + interval '2 days'
    group by 1)
  select jsonb_agg(jsonb_build_object(
      'date', d.day,
      'opdVisits', coalesce((select sum(n) from visits v where v.day = d.day), 0),
      'newPatients', coalesce((select n from pts where pts.day = d.day), 0),
      'noShows', coalesce((select n from noshow where noshow.day = d.day), 0),
      'billedPaise', coalesce((select billed from bills where bills.day = d.day), 0),
      'discountPaise', coalesce((select disc from bills where bills.day = d.day), 0),
      'creditNotePaise', coalesce((select cn from bills where bills.day = d.day), 0),
      'collectedPaise', coalesce((select coll from pays where pays.day = d.day), 0),
      'refundPaise', coalesce((select refund from pays where pays.day = d.day), 0),
      'pharmacySales', coalesce((select n from rx where rx.day = d.day), 0),
      'pharmacySalesPaise', coalesce((select amt from rx where rx.day = d.day), 0)) order by d.day)
  into v_days from d;

  select coalesce(jsonb_object_agg(m.mode, m.amt), '{}'::jsonb) into v_modes
  from (
    select t.mode, sum(t.amount_paise) filter (where p.kind <> 'refund') - coalesce(sum(t.amount_paise) filter (where p.kind = 'refund'), 0) as amt
    from billing.payment p
    join billing.billing_account ac on ac.id = p.account_id and ac.tenant_id = p.tenant_id
    join billing.payment_tender t on t.payment_id = p.id and not t.is_deleted
    where p.tenant_id = p_tenant_id and not p.is_deleted and ac.branch_id = any(v_branches)
      and identity.branch_local_date_v1(ac.branch_id, p.received_at) between p_from and p_to
    group by t.mode) m;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'branchId', p_branch_id,
    'totals', (select jsonb_object_agg(k, s) from (
        select k, sum((e ->> k)::bigint) as s
        from jsonb_array_elements(v_days) e, jsonb_object_keys(e) k where k <> 'date' group by k) z),
    'byMode', v_modes,
    'days', v_days);
end;
$$;

revoke all on function billing.owner_kpis(uuid, date, date, uuid) from public, anon, authenticated;
grant execute on function billing.owner_kpis(uuid, date, date, uuid) to hms_svc_billing, service_role;
