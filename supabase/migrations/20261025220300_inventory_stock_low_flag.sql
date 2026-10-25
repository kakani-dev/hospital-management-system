-- BUG-49: stock on hand flags a batch when the store's on-hand quantity for that item
-- is below store_item_policy.min_qty (the reorder level). p_low_only keeps those rows.
-- cross-schema: approved (branch scope uses identity.current_branch_ids, as the previous function did)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

drop function inventory.stock_on_hand(uuid, uuid, uuid);

create function inventory.stock_on_hand(
  p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_low_only boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
        when b.expiry_date < current_date then 'expired'
        when b.expiry_date <= current_date + 90 then 'soon'
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
$$;

revoke all on function inventory.stock_on_hand(uuid, uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function inventory.stock_on_hand(uuid, uuid, uuid, boolean) to hms_svc_inventory, service_role;
