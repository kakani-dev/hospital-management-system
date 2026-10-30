-- cross-schema: approved (reads patient.patients name + MRN for the bills list inside a security-definer function, read-only, same as pharmacy.rx_json; every role with billing.view (tenant_admin, receptionist, billing) can already read patients under patient RLS)
-- #125/#126: the bills list timed out (504 with no filter, 500 for finalized) once a tenant had a few
-- hundred bills. billing.list_bills joined bill_totals_v1 / bill_balance_v1 for every bill before the
-- limit, and every row of every nested view re-ran the RLS subqueries (current_tenant_ids /
-- current_branch_ids), so cost grew with bills x lines x credit notes.
-- Now: security definer with the permission and branch scope checked once from the JWT (same pattern as
-- billing.earnings_report_base), the page of 200 bills is picked first, and totals/dues are computed only
-- for that page. Order is unchanged.
-- #124: each row also carries patientName and patientMrn so drafts can be told apart.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.list_bills(p_tenant_id uuid, p_status text, p_branch_id uuid, p_from date, p_to date)
returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_branches uuid[];
begin
  -- #125/#126: definer so the per-row RLS subqueries (current_tenant_ids /
  -- current_branch_ids on bill, bill_line, discount, account) are not run for
  -- every row of every totals view. The owner would pass billing.bypass_acl(),
  -- so the caller's permission and branch scope are checked here, explicitly,
  -- once, from the JWT. The tenant id comes from the API's server-side claim.
  if p_tenant_id is null
     or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.view') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  v_branches := array(select identity.current_branch_ids(p_tenant_id));
  if p_branch_id is not null then
    if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
      raise exception 'branch not found' using errcode = 'P0002';
    end if;
    if not (p_branch_id = any(v_branches)) then
      raise exception 'branch out of scope' using errcode = '42501';
    end if;
  end if;

  -- Pick the page first; totals and dues are computed only for those rows.
  return coalesce((
    with page as materialized (
      select b.id, b.bill_no, b.status, b.bill_kind, b.created_on,
             a.patient_id, a.branch_id, a.tenant_id
      from billing.bill b
      join billing.billing_account a on a.id = b.account_id and a.tenant_id = b.tenant_id
      where b.tenant_id = p_tenant_id and not b.is_deleted
        and a.branch_id = any(v_branches)
        and (v_status is null or b.status = v_status)
        and (p_branch_id is null or a.branch_id = p_branch_id)
        and (p_from is null or (b.created_on at time zone identity.branch_time_zone_v1(a.branch_id))::date >= p_from)
        and (p_to is null or (b.created_on at time zone identity.branch_time_zone_v1(a.branch_id))::date <= p_to)
      order by b.created_on desc
      limit 200
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x."createdOn" desc, x.id)
    from (
      select p.id, p.bill_no as "billNo", p.status, p.bill_kind as "billKind",
             p.patient_id as "patientId", p.branch_id as "branchId",
             nullif(btrim(pt.first_name || ' ' || pt.last_name), '') as "patientName", pt.mrn as "patientMrn",
             bal.total_paise as "totalPaise", bal.due_paise as "duePaise",
             p.created_on as "createdOn"
      from page p
      left join patient.patients pt on pt.tenant_id = p.tenant_id and pt.id = p.patient_id
      left join lateral (
        select v.total_paise, v.due_paise from billing.bill_balance_v1 v where v.bill_id = p.id
      ) bal on true
    ) x
  ), '[]'::jsonb);
end;
$function$;

revoke all on function billing.list_bills(uuid, text, uuid, date, date) from public, anon;
grant execute on function billing.list_bills(uuid, text, uuid, date, date) to hms_svc_billing;
