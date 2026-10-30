-- cross-schema: approved (inventory.tenant_today reads identity.tenants.time_zone; read-only, same pattern as inventory.branch_today in #189)
-- #208: inventory.create_item stamped the first item_gst row with the UTC current_date.
-- Now uses the tenant-local date (tenant time zone, Asia/Kolkata if unknown). Tenant-wide items
-- have no branch, so the tenant zone is the right clock.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function inventory.tenant_today(p_tenant_id uuid, p_at timestamptz default now())
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (p_at at time zone coalesce(
    (select t.time_zone from identity.tenants t where t.id = p_tenant_id), 'Asia/Kolkata'))::date
$$;
revoke all on function inventory.tenant_today(uuid, timestamptz) from public, anon;
grant execute on function inventory.tenant_today(uuid, timestamptz) to authenticated, hms_svc_inventory, service_role;

CREATE OR REPLACE FUNCTION inventory.create_item(p_tenant_id uuid, p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_kind text := p_body ->> 'itemKind';
  v_brand text := btrim(p_body ->> 'brandName');
  v_generic text := nullif(btrim(p_body ->> 'genericName'), '');
  v_strength text := coalesce(btrim(p_body ->> 'strength'), '');
  v_form text := coalesce(btrim(p_body ->> 'dosageForm'), '');
  v_route text := nullif(btrim(p_body ->> 'route'), '');
  v_maker text := btrim(p_body ->> 'manufacturerName');
  v_schedule text := nullif(btrim(p_body ->> 'scheduleCode'), '');
  v_hsn text := btrim(p_body ->> 'hsnCode');
  v_uom text := upper(btrim(p_body ->> 'baseUomCode'));
  v_bp integer;
  v_maker_id uuid;
  v_generic_id uuid;
  v_gst_id uuid;
  v_item uuid;
  v_code text;
  v_store uuid := nullif(p_body ->> 'storeId', '')::uuid;
  v_reorder bigint;
  v_pack jsonb;
  v_pack_uom text;
  v_units bigint;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.catalog');
  perform inventory.reject_supplied(p_body);
  if v_kind is null or v_kind not in ('drug', 'consumable', 'implant', 'reagent', 'general') then
    raise exception 'itemKind must be drug, consumable, implant, reagent, or general' using errcode = '22023';
  end if;
  if v_brand is null or v_brand = '' then
    raise exception 'brandName is required' using errcode = '22023';
  end if;
  if v_kind = 'drug' and v_generic is null then
    raise exception 'genericName is required for a drug' using errcode = '22023';
  end if;
  if v_maker is null or v_maker = '' then
    raise exception 'manufacturerName is required' using errcode = '22023';
  end if;
  if v_schedule is not null and v_schedule not in ('OTC', 'G', 'H', 'H1', 'X', 'NDPS') then
    raise exception 'scheduleCode must be OTC, G, H, H1, X, or NDPS' using errcode = '22023';
  end if;
  if v_kind <> 'drug' and v_schedule is not null then
    raise exception 'only a drug has a schedule' using errcode = '22023';
  end if;
  if v_hsn is null or v_hsn !~ '^[0-9]{4,8}$' then
    raise exception 'hsnCode must be 4 to 8 digits' using errcode = '22023';
  end if;
  if jsonb_typeof(p_body -> 'gstRateBp') is distinct from 'number' then
    raise exception 'gstRateBp is required' using errcode = '22023';
  end if;
  v_bp := (p_body ->> 'gstRateBp')::integer;
  if v_bp < 0 or v_bp > 10000 then
    raise exception 'gstRateBp must be between 0 and 10000' using errcode = '22023';
  end if;
  if v_uom is null or not exists (select 1 from inventory.uom u where u.code = v_uom and not u.is_deleted) then
    raise exception 'baseUomCode is not a known unit' using errcode = '22023';
  end if;
  if p_body ? 'packs' and jsonb_typeof(p_body -> 'packs') is distinct from 'array' then
    raise exception 'packs must be a list' using errcode = '22023';
  end if;
  if (p_body ? 'storeId') <> (p_body ? 'reorderLevel') then
    raise exception 'storeId and reorderLevel are set together' using errcode = '22023';
  end if;

  select m.id into v_maker_id
  from inventory.manufacturer m
  where m.tenant_id = p_tenant_id and lower(btrim(m.name)) = lower(v_maker) and not m.is_deleted
  limit 1;
  if v_maker_id is null then
    insert into inventory.manufacturer (tenant_id, name) values (p_tenant_id, v_maker)
    returning id into v_maker_id;
  end if;

  if v_generic is not null then
    select g.id into v_generic_id
    from inventory.generic g
    where g.tenant_id = p_tenant_id
      and lower(btrim(g.name)) = lower(v_generic)
      and lower(btrim(g.strength)) = lower(v_strength)
      and lower(btrim(g.dosage_form)) = lower(v_form)
      and not g.is_deleted
    limit 1;
    if v_generic_id is null then
      insert into inventory.generic (tenant_id, name, strength, dosage_form, route)
      values (p_tenant_id, v_generic, v_strength, v_form, v_route)
      returning id into v_generic_id;
    end if;
  end if;

  select r.id into v_gst_id
  from inventory.gst_rate r
  where r.tenant_id = p_tenant_id and r.rate_bp = v_bp and not r.is_deleted
  order by r.effective_from desc
  limit 1;
  if v_gst_id is null then
    insert into inventory.gst_rate (tenant_id, rate_bp, effective_from)
    values (p_tenant_id, v_bp, date '2017-07-01')
    returning id into v_gst_id;
  end if;

  v_code := inventory.next_code(p_tenant_id, 'item', 'ITM');
  insert into inventory.item (
    tenant_id, code, generic_id, brand_name, manufacturer_id, item_kind, schedule_code,
    hsn_code, base_uom_code, is_cold_chain, is_high_alert, is_lasa
  ) values (
    p_tenant_id, v_code, v_generic_id, v_brand, v_maker_id, v_kind, v_schedule,
    v_hsn, v_uom,
    coalesce((p_body ->> 'isColdChain')::boolean, false),
    coalesce((p_body ->> 'isHighAlert')::boolean, false),
    coalesce((p_body ->> 'isLasa')::boolean, false)
  ) returning id into v_item;

  insert into inventory.item_gst (tenant_id, item_id, gst_rate_id, effective_from)
  values (p_tenant_id, v_item, v_gst_id, inventory.tenant_today(p_tenant_id));

  for v_pack in
    select value from jsonb_array_elements(coalesce(p_body -> 'packs', '[]'::jsonb))
  loop
    v_pack_uom := upper(btrim(v_pack ->> 'uomCode'));
    if jsonb_typeof(v_pack -> 'unitsPerPack') is distinct from 'number' then
      raise exception 'unitsPerPack is required' using errcode = '22023';
    end if;
    v_units := (v_pack ->> 'unitsPerPack')::bigint;
    if v_pack_uom is null or not exists (select 1 from inventory.uom u where u.code = v_pack_uom and not u.is_deleted) then
      raise exception 'pack uomCode is not a known unit' using errcode = '22023';
    end if;
    if v_units is null or v_units <= 1 then
      raise exception 'unitsPerPack must be greater than 1' using errcode = '22023';
    end if;
    insert into inventory.item_pack (tenant_id, item_id, uom_code, units_per_pack, is_purchase, is_sale)
    values (
      p_tenant_id, v_item, v_pack_uom, v_units,
      coalesce((v_pack ->> 'isPurchase')::boolean, false),
      coalesce((v_pack ->> 'isSale')::boolean, false)
    );
  end loop;

  if v_store is not null then
    if jsonb_typeof(p_body -> 'reorderLevel') is distinct from 'number' then
      raise exception 'reorderLevel must be a number' using errcode = '22023';
    end if;
    v_reorder := (p_body ->> 'reorderLevel')::bigint;
    if v_reorder < 0 then
      raise exception 'reorderLevel cannot be negative' using errcode = '22023';
    end if;
    if not exists (
      select 1 from inventory.store s
      where s.id = v_store and s.tenant_id = p_tenant_id and not s.is_deleted
    ) then
      raise exception 'store not found' using errcode = 'P0002';
    end if;
    insert into inventory.store_item_policy (store_id, item_id, tenant_id, min_qty)
    values (v_store, v_item, p_tenant_id, v_reorder);
  end if;

  return inventory.item_json(v_item);
end;
$function$
;
