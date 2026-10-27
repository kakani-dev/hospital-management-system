-- #176: earnings split by category (consult / procedure / lab / other).
-- The 650-line billing.earnings_report body is kept as-is under a new name; the public
-- function calls it and adds 'categories', computed from the same per-call temp lines
-- (pg_temp.earn_line, on commit drop, still present in this transaction).
-- Buckets come from billing.service_item.category: consultation -> consult,
-- procedure -> procedure, lab -> lab, everything else (imaging, consumable, room,
-- package, other, or an unlinked line) -> other. Same basis as 'services':
-- net + tax of finalised lines, credit notes excluded, same period and branch focus.

alter function billing.earnings_report(uuid, date, date, uuid, text, integer, integer)
  rename to earnings_report_base;
revoke all on function billing.earnings_report_base(uuid, date, date, uuid, text, integer, integer) from public, anon, authenticated;

create or replace function billing.earnings_category_bucket(p_category text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_category
           when 'consultation' then 'consult'
           when 'procedure' then 'procedure'
           when 'lab' then 'lab'
           else 'other' end
$$;
revoke all on function billing.earnings_category_bucket(text) from public, anon, authenticated;
grant execute on function billing.earnings_category_bucket(text) to hms_svc_billing;

create or replace function billing.earnings_report(
  p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid, p_grain text, p_fy integer, p_quarter integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_report jsonb;
  v_from date;
  v_to date;
  v_focus uuid;
begin
  v_report := billing.earnings_report_base(p_tenant_id, p_from, p_to, p_branch_id, p_grain, p_fy, p_quarter);
  if v_report is null or jsonb_typeof(v_report) <> 'object' or not (v_report ? 'from') then
    return v_report;
  end if;
  v_from := (v_report ->> 'from')::date;
  v_to := (v_report ->> 'to')::date;
  v_focus := nullif(v_report ->> 'branchId', '')::uuid;
  return v_report || jsonb_build_object('categories', (
    select jsonb_agg(jsonb_build_object(
             'category', r.category, 'revenuePaise', r.revenue, 'lineCount', r.lines,
             'sharePct', case when r.total = 0 then 0 else round(r.revenue::numeric / r.total * 100, 1) end)
             order by r.ord)
    from (
      select k.ord, k.category, coalesce(c.revenue, 0) as revenue, coalesce(c.lines, 0) as lines,
             coalesce(sum(c.revenue) over (), 0) as total
      from (values (1, 'consult'), (2, 'procedure'), (3, 'lab'), (4, 'other')) as k(ord, category)
      left join (
        select billing.earnings_category_bucket(si.category) as category,
               sum(l.net_paise + l.tax_paise) as revenue,
               count(*) as lines
        from pg_temp.earn_line l
        left join billing.service_item si on si.id = l.service_item_id
        where l.bill_kind <> 'credit_note' and l.bill_date between v_from and v_to
          and (v_focus is null or l.branch_id = v_focus)
        group by 1
      ) c on c.category = k.category
    ) r));
end;
$$;
revoke all on function billing.earnings_report(uuid, date, date, uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function billing.earnings_report(uuid, date, date, uuid, text, integer, integer) to hms_svc_billing;
grant execute on function billing.earnings_report_base(uuid, date, date, uuid, text, integer, integer) to hms_svc_billing;
