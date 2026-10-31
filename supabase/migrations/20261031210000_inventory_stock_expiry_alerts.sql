-- cross-schema: approved (pharmacy schema hosted by the inventory service per docs/adr/0004; branch scope uses identity.current_branch_ids / has_tenant_permission as stock_on_hand does)
-- Pharmacy stock and expiry alerts. Near-expiry window is a tenant setting (near_expiry_days,
-- default 90, 1..365) instead of the fixed 90 in stock_on_hand. inventory.stock_alerts lists, for the
-- caller's branches: items below the store reorder level (store_item_policy.min_qty) and expired /
-- near-expiry batches still on the shelf, earliest expiry first (FEFO). Dispensing already skips
-- expired batches (pharmacy.dispense / fefo_pick_v1); that is unchanged.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table pharmacy.tenant_setting
  add column if not exists near_expiry_days integer not null default 90
  constraint tenant_setting_near_expiry_days_check check (near_expiry_days between 1 and 365);

create or replace function pharmacy.near_expiry_days(p_tenant_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select s.near_expiry_days from pharmacy.tenant_setting s where s.tenant_id = p_tenant_id), 90)
$$;
revoke execute on function pharmacy.near_expiry_days(uuid) from public, anon, authenticated;
grant execute on function pharmacy.near_expiry_days(uuid) to hms_svc_inventory, service_role;

create or replace function pharmacy.get_settings(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())
     or not (identity.has_tenant_permission(p_tenant_id, 'pharmacy.view')
             or identity.has_tenant_permission(p_tenant_id, 'inventory.view')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'rxValidityDays', pharmacy.rx_validity_days(p_tenant_id),
    'nearExpiryDays', pharmacy.near_expiry_days(p_tenant_id));
end;
$$;

create or replace function pharmacy.set_alert_settings(p_tenant_id uuid, p_body jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_near integer;
  v_rx integer;
begin
  if auth.uid() is null or p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())
     or not identity.has_tenant_permission(p_tenant_id, 'settings.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_body is null or jsonb_typeof(p_body) <> 'object' then
    raise exception 'body must be an object' using errcode = '22023';
  end if;
  if p_body ? 'nearExpiryDays' then
    if jsonb_typeof(p_body -> 'nearExpiryDays') <> 'number' then
      raise exception 'nearExpiryDays must be a number' using errcode = '22023';
    end if;
    v_near := (p_body ->> 'nearExpiryDays')::numeric;
    if v_near::numeric <> (p_body ->> 'nearExpiryDays')::numeric or v_near < 1 or v_near > 365 then
      raise exception 'near-expiry window must be between 1 and 365 days' using errcode = '22023';
    end if;
  end if;
  if p_body ? 'rxValidityDays' then
    if jsonb_typeof(p_body -> 'rxValidityDays') <> 'number' then
      raise exception 'rxValidityDays must be a number' using errcode = '22023';
    end if;
    v_rx := (p_body ->> 'rxValidityDays')::numeric;
    if v_rx::numeric <> (p_body ->> 'rxValidityDays')::numeric or v_rx < 1 or v_rx > 365 then
      raise exception 'rx validity must be between 1 and 365 days' using errcode = '22023';
    end if;
  end if;
  insert into pharmacy.tenant_setting (tenant_id, rx_validity_days, near_expiry_days, updated_by, updated_on)
  values (p_tenant_id, coalesce(v_rx, pharmacy.rx_validity_days(p_tenant_id)),
          coalesce(v_near, pharmacy.near_expiry_days(p_tenant_id)), auth.uid(), now())
  on conflict (tenant_id) do update
    set rx_validity_days = coalesce(v_rx, pharmacy.tenant_setting.rx_validity_days),
        near_expiry_days = coalesce(v_near, pharmacy.tenant_setting.near_expiry_days),
        updated_by = excluded.updated_by, updated_on = now();
  return jsonb_build_object(
    'rxValidityDays', pharmacy.rx_validity_days(p_tenant_id),
    'nearExpiryDays', pharmacy.near_expiry_days(p_tenant_id));
end;
$$;
revoke execute on function pharmacy.set_alert_settings(uuid, jsonb) from public, anon, authenticated;
grant execute on function pharmacy.set_alert_settings(uuid, jsonb) to hms_svc_inventory;

-- Reorder level / quantity for one item in one store (that store's branch). Upsert.
create or replace function inventory.set_reorder_policy(p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_body jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_min bigint;
  v_reorder bigint;
  v_branch uuid;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.catalog');
  select s.branch_id into v_branch from inventory.store s
  where s.id = p_store_id and s.tenant_id = p_tenant_id and not s.is_deleted;
  if v_branch is null or not exists (
       select 1 from inventory.item i where i.id = p_item_id and i.tenant_id = p_tenant_id and not i.is_deleted) then
    raise exception 'store or item not found' using errcode = 'P0002';
  end if;
  perform inventory.assert_branch(p_tenant_id, v_branch);
  if p_body is null or jsonb_typeof(p_body -> 'reorderLevel') is distinct from 'number' then
    raise exception 'reorderLevel must be a number' using errcode = '22023';
  end if;
  v_min := (p_body ->> 'reorderLevel')::numeric;
  if v_min::numeric <> (p_body ->> 'reorderLevel')::numeric or v_min < 0 then
    raise exception 'reorderLevel must be a whole number, 0 or more' using errcode = '22023';
  end if;
  if p_body ? 'reorderQty' and jsonb_typeof(p_body -> 'reorderQty') <> 'null' then
    if jsonb_typeof(p_body -> 'reorderQty') <> 'number' then
      raise exception 'reorderQty must be a number' using errcode = '22023';
    end if;
    v_reorder := (p_body ->> 'reorderQty')::numeric;
    if v_reorder::numeric <> (p_body ->> 'reorderQty')::numeric or v_reorder < 1 then
      raise exception 'reorderQty must be a whole number, 1 or more' using errcode = '22023';
    end if;
  end if;
  insert into inventory.store_item_policy (store_id, item_id, tenant_id, min_qty, reorder_qty, created_by, updated_by)
  values (p_store_id, p_item_id, p_tenant_id, v_min, v_reorder, auth.uid(), auth.uid())
  on conflict (store_id, item_id) do update
    set min_qty = excluded.min_qty, reorder_qty = excluded.reorder_qty, is_deleted = false,
        updated_by = excluded.updated_by, updated_on = now();
  return jsonb_build_object('storeId', p_store_id, 'itemId', p_item_id, 'reorderLevel', v_min, 'reorderQty', v_reorder);
end;
$$;
revoke execute on function inventory.set_reorder_policy(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function inventory.set_reorder_policy(uuid, uuid, uuid, jsonb) to hms_svc_inventory, service_role;

create or replace function inventory.stock_alerts(p_tenant_id uuid, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_days integer;
  v_low jsonb;
  v_exp jsonb;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  v_days := pharmacy.near_expiry_days(p_tenant_id);

  with scope as (
    select s.* from inventory.store s
    where s.tenant_id = p_tenant_id and not s.is_deleted
      and (p_branch_id is null or s.branch_id = p_branch_id)
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'kind', 'low_stock', 'storeId', s.id, 'storeName', s.name, 'branchId', s.branch_id,
      'itemId', i.id, 'itemCode', i.code, 'brandName', i.brand_name, 'baseUomCode', i.base_uom_code,
      'onHandBase', q.qty, 'reorderLevel', pol.min_qty, 'reorderQty', pol.reorder_qty,
      'suggestedQty', coalesce(pol.reorder_qty, greatest(pol.min_qty * 2 - q.qty, 1)))
    order by (q.qty::numeric / nullif(pol.min_qty, 0)), s.name, i.brand_name), '[]'::jsonb)
  into v_low
  from scope s
  join inventory.store_item_policy pol on pol.store_id = s.id and pol.tenant_id = p_tenant_id and not pol.is_deleted
  join inventory.item i on i.id = pol.item_id and not i.is_deleted
  cross join lateral (
    select coalesce(sum(c.on_hand_base), 0) as qty
    from inventory.stock_balance_cache c
    join inventory.batch b on b.id = c.batch_id and not b.is_deleted
    where c.store_id = s.id and b.item_id = i.id
      and b.expiry_date >= inventory.store_today(s.id)
  ) q
  where pol.min_qty > 0 and q.qty < pol.min_qty;

  with scope as (
    select s.*, inventory.store_today(s.id) as today from inventory.store s
    where s.tenant_id = p_tenant_id and not s.is_deleted
      and (p_branch_id is null or s.branch_id = p_branch_id)
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'kind', case when b.expiry_date < s.today then 'expired' else 'near_expiry' end,
      'storeId', s.id, 'storeName', s.name, 'branchId', s.branch_id,
      'itemId', i.id, 'itemCode', i.code, 'brandName', i.brand_name, 'baseUomCode', i.base_uom_code,
      'batchId', b.id, 'batchNo', b.batch_no, 'expiryDate', b.expiry_date,
      'daysLeft', b.expiry_date - s.today, 'onHandBase', c.on_hand_base,
      'valuePaise', c.on_hand_base * b.mrp_paise)
    order by b.expiry_date, s.name, i.brand_name, b.id), '[]'::jsonb)
  into v_exp
  from scope s
  join inventory.stock_balance_cache c on c.store_id = s.id and c.on_hand_base > 0
  join inventory.batch b on b.id = c.batch_id and not b.is_deleted
  join inventory.item i on i.id = b.item_id and not i.is_deleted
  where b.expiry_date <= s.today + v_days;

  return jsonb_build_object(
    'nearExpiryDays', v_days,
    'counts', jsonb_build_object(
      'lowStock', jsonb_array_length(v_low),
      'nearExpiry', (select count(*) from jsonb_array_elements(v_exp) e where e ->> 'kind' = 'near_expiry'),
      'expired', (select count(*) from jsonb_array_elements(v_exp) e where e ->> 'kind' = 'expired')),
    'lowStock', v_low,
    'expiry', v_exp);
end;
$$;
revoke execute on function inventory.stock_alerts(uuid, uuid) from public, anon, authenticated;
grant execute on function inventory.stock_alerts(uuid, uuid) to hms_svc_inventory, service_role;
comment on function inventory.stock_alerts(uuid, uuid) is
  'Low-stock (below store reorder level, unexpired stock only) and expired / near-expiry batches (tenant near_expiry_days), earliest expiry first. Caller branches only.';

-- inventory.stock_on_hand: 2 date check(s) now branch-local
CREATE OR REPLACE FUNCTION inventory.stock_on_hand(p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_low_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'storeId', s.id,
      'storeCode', s.code,
      'storeName', s.name,
      'itemId', i.id,
      'itemCode', i.code,
      'brandName', i.brand_name,
      'batchId', b.id,
      'batchNo', b.batch_no,
      'expiryDate', b.expiry_date,
      'mrpPaise', b.mrp_paise,
      'purchaseRatePaise', (
        select l.unit_cost_paise
        from inventory.stock_ledger l
        where l.store_id = c.store_id and l.batch_id = c.batch_id
        order by l.seq desc
        limit 1
      ),
      'onHandBase', c.on_hand_base,
      'baseUomCode', i.base_uom_code,
      'minQty', pol.min_qty,
      'lowStock', pol.min_qty is not null and totals.qty < pol.min_qty,
      'expiryState', case
        when b.expiry_date < inventory.store_today(c.store_id) then 'expired'
        when b.expiry_date <= inventory.store_today(c.store_id) + pharmacy.near_expiry_days(p_tenant_id) then 'soon'
        else 'ok'
      end
    ) order by s.code, i.code, b.expiry_date, b.id)
    from inventory.stock_balance_cache c
    join inventory.store s on s.id = c.store_id
    join inventory.batch b on b.id = c.batch_id
    join inventory.item i on i.id = b.item_id
    left join inventory.store_item_policy pol
      on pol.tenant_id = c.tenant_id and pol.store_id = c.store_id and pol.item_id = i.id and not pol.is_deleted
    left join lateral (
      select coalesce(sum(c2.on_hand_base), 0) as qty
      from inventory.stock_balance_cache c2
      join inventory.batch b2 on b2.id = c2.batch_id and not b2.is_deleted
      where c2.tenant_id = c.tenant_id and c2.store_id = c.store_id and b2.item_id = i.id
    ) totals on true
    where c.tenant_id = p_tenant_id
      and c.on_hand_base > 0
      and not s.is_deleted
      and not b.is_deleted
      and not i.is_deleted
      and (p_store_id is null or c.store_id = p_store_id)
      and (p_item_id is null or b.item_id = p_item_id)
      and (not p_low_only or (pol.min_qty is not null and totals.qty < pol.min_qty))
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ), '[]'::jsonb);
end;
$function$;
