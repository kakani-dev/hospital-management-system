-- cross-schema: approved (inventory calls identity.current_tenant_ids and identity.has_tenant_permission
-- through inventory.assert_permission, and audit.stamp_audit_columns / audit.log_row_change /
-- audit.prevent_tenant_change. No table reads outside inventory.)
-- Pharmacy barcode scanning: each hospital links a GS1 GTIN (the product code on a medicine pack) to one
-- of its own catalogue items, once. The tenant always comes from the server; RLS keeps rows per hospital.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table inventory.item_gtin (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  gtin        text not null,
  item_id     uuid not null references inventory.item (id),
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint item_gtin_shape check (gtin ~ '^[0-9]{14}$')
);
create unique index item_gtin_key on inventory.item_gtin (tenant_id, gtin) where not is_deleted;
create index item_gtin_item on inventory.item_gtin (tenant_id, item_id) where not is_deleted;
comment on table inventory.item_gtin is
  'Per-hospital link from a GS1 GTIN-14 to a catalogue item, made once at first scan. Batch and expiry stay on the batch.';

create trigger item_gtin_audit_columns before insert or update on inventory.item_gtin
  for each row execute function audit.stamp_audit_columns();
create trigger item_gtin_tenant_immutable before update on inventory.item_gtin
  for each row execute function audit.prevent_tenant_change();
create trigger item_gtin_audit_log after insert or update or delete on inventory.item_gtin
  for each row execute function audit.log_row_change();

alter table inventory.item_gtin enable row level security;
create policy item_gtin_tenant on inventory.item_gtin
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));
revoke all on inventory.item_gtin from public, anon, authenticated;
grant select on inventory.item_gtin to hms_svc_inventory;

-- Looks up a scanned GTIN. Returns {gtin, item} where item is null when this hospital has not linked it yet.
create or replace function inventory.resolve_gtin(p_tenant_id uuid, p_gtin text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_item uuid;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  if p_gtin is null or p_gtin !~ '^[0-9]{14}$' then
    raise exception 'gtin must be 14 digits' using errcode = '22023';
  end if;
  select g.item_id into v_item
  from inventory.item_gtin g
  join inventory.item i on i.id = g.item_id and i.tenant_id = g.tenant_id and not i.is_deleted
  where g.tenant_id = p_tenant_id and g.gtin = p_gtin and not g.is_deleted;
  return jsonb_build_object('gtin', p_gtin,
    'item', case when v_item is null then null else inventory.item_json(v_item) end);
end;
$$;

-- One-time link. Linking the same GTIN to the same item again is a no-op; to a different item it is refused.
create or replace function inventory.link_gtin(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gtin text := p_body ->> 'gtin';
  v_item uuid;
  v_existing uuid;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.catalog');
  if v_gtin is null or v_gtin !~ '^[0-9]{14}$' then
    raise exception 'gtin must be 14 digits' using errcode = '22023';
  end if;
  begin
    v_item := (p_body ->> 'itemId')::uuid;
  exception when invalid_text_representation then
    raise exception 'itemId must be a UUID' using errcode = '22023';
  end;
  if v_item is null or not exists (
    select 1 from inventory.item i where i.id = v_item and i.tenant_id = p_tenant_id and not i.is_deleted) then
    raise exception 'item was not found' using errcode = 'P0002';
  end if;
  select g.item_id into v_existing
  from inventory.item_gtin g where g.tenant_id = p_tenant_id and g.gtin = v_gtin and not g.is_deleted
  for update;
  if v_existing is not null and v_existing <> v_item then
    raise exception 'this barcode is already linked to another item' using errcode = '23505';
  end if;
  if v_existing is null then
    insert into inventory.item_gtin (tenant_id, gtin, item_id, created_by, updated_by)
    values (p_tenant_id, v_gtin, v_item, auth.uid(), auth.uid());
  end if;
  return inventory.resolve_gtin(p_tenant_id, v_gtin);
end;
$$;

revoke execute on function inventory.resolve_gtin(uuid, text) from public, anon, authenticated;
revoke execute on function inventory.link_gtin(uuid, jsonb) from public, anon, authenticated;
grant execute on function inventory.resolve_gtin(uuid, text) to hms_svc_inventory, service_role;
grant execute on function inventory.link_gtin(uuid, jsonb) to hms_svc_inventory, service_role;
