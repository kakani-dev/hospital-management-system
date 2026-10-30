-- cross-schema: approved (billing.tenant_today reads identity.tenants.time_zone; read-only, same pattern as inventory.branch_today in #189)
-- #207: billing.list_service_items picked the current price with the UTC current_date, so from 00:00 to
-- 05:30 IST a price starting today was hidden and one ending today stayed in use.
-- Now uses the tenant-local date (tenant time zone, Asia/Kolkata if unknown). Tenant-wide price lists
-- have no branch, so the tenant zone is the right clock.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.tenant_today(p_tenant_id uuid, p_at timestamptz default now())
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (p_at at time zone coalesce(
    (select t.time_zone from identity.tenants t where t.id = p_tenant_id), 'Asia/Kolkata'))::date
$$;
revoke all on function billing.tenant_today(uuid, timestamptz) from public, anon;
grant execute on function billing.tenant_today(uuid, timestamptz) to authenticated, hms_svc_billing, service_role;

CREATE OR REPLACE FUNCTION billing.list_service_items(p_tenant_id uuid, p_query text, p_include_inactive boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_q text := nullif(lower(btrim(coalesce(p_query, ''))), '');
begin
  perform billing.assert_catalog_read(p_tenant_id);
  perform billing.ensure_defaults(p_tenant_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', si.id,
      'code', si.code,
      'name', si.name,
      'category', si.category,
      'taxCodeId', si.tax_code_id,
      'sacHsnCode', tc.sac_hsn_code,
      'taxRateBp', tc.rate_bp,
      'isExempt', tc.is_exempt,
      'isActive', si.is_active,
      'isStockTracked', si.is_stock_tracked,
      'hospitalPricePaise', hospital.unit_price_paise
    ) order by si.code)
    from billing.service_item si
    join billing.tax_code tc on tc.id = si.tax_code_id
    left join lateral (
      select pli.unit_price_paise
      from billing.price_list_item pli
      join billing.price_list pl
        on pl.id = pli.price_list_id
       and pl.branch_id is null
       and pl.is_active
       and not pl.is_deleted
      where pli.service_item_id = si.id
        and pli.tenant_id = si.tenant_id
        and pli.practitioner_id is null
        and not pli.is_deleted
        and pli.effective_from <= billing.tenant_today(p_tenant_id)
        and (pli.effective_to is null or pli.effective_to > billing.tenant_today(p_tenant_id))
      order by pli.effective_from desc
      limit 1
    ) hospital on true
    where si.tenant_id = p_tenant_id
      and not si.is_deleted
      and (coalesce(p_include_inactive, false) or si.is_active)
      and (
        v_q is null
        or position(v_q in lower(si.code)) > 0
        or position(v_q in lower(si.name)) > 0
        or position(v_q in lower(si.category)) > 0
        or position(v_q in lower(tc.sac_hsn_code)) > 0
      )
  ), '[]'::jsonb);
end;
$function$
;

