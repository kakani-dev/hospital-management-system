-- cross-schema: approved (inventory calls identity.branch_exists_v1, identity.current_tenant_ids,
-- identity.current_branch_ids, identity.has_tenant_permission, and audit.session_actor_id /
-- audit.stamp_audit_columns. No table reads outside inventory. Login hms_inventory_login stays
-- out of band. Purchase rate is stock_ledger.unit_cost_paise, not a column on batch.)
-- Inventory foundation (pharmacy/stock slice 1). Item, store, batch, immutable stock ledger,
-- balance cache, opening stock, and a FEFO lookup. Later slices add purchase, transfer, and dispense.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'hms_svc_inventory') then
    create role hms_svc_inventory nologin noinherit;
  end if;
end
$$;

grant anon to hms_svc_inventory;
revoke authenticated from hms_svc_inventory;

comment on role hms_svc_inventory is
  'Inventory service session role (Database:SessionRole). Owns no tables. Reads other services only through published _v1 functions.';

create schema if not exists inventory;
revoke all on schema inventory from public;
grant usage on schema inventory to hms_svc_inventory;

comment on schema inventory is
  'Stock owned by the inventory service. The ledger is the only quantity. Pharmacy, purchase, and assets are later slices.';

-- --------------------------------------------------------------------- catalogs ----
create table inventory.uom (
  code        text primary key,
  name        text not null,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint uom_code_shape check (code ~ '^[A-Z]{2,8}$')
);
comment on table inventory.uom is
  'Unit of measure catalog. Shared by every hospital. Not copied onto a pack as a second fact.';

create table inventory.manufacturer (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  name        text not null,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint manufacturer_name_present check (btrim(name) <> '')
);
create unique index manufacturer_name_key
  on inventory.manufacturer (tenant_id, lower(btrim(name)))
  where not is_deleted;

create table inventory.generic (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  name         text not null,
  strength     text not null default '',
  dosage_form  text not null default '',
  route        text,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint generic_name_present check (btrim(name) <> '')
);
create unique index generic_identity_key
  on inventory.generic (tenant_id, lower(btrim(name)), lower(btrim(strength)), lower(btrim(dosage_form)))
  where not is_deleted;
comment on table inventory.generic is
  'Drug identity for substitution: name, strength, and form. The brand lives on the item.';

create table inventory.gst_rate (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  rate_bp         integer not null,
  effective_from  date not null,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint gst_rate_bp_range check (rate_bp between 0 and 10000),
  constraint gst_rate_key unique (tenant_id, rate_bp, effective_from)
);
comment on table inventory.gst_rate is
  'GST rate in basis points. The item points at a rate; the percent is not copied onto the item.';

-- --------------------------------------------------------------------- counters ----
-- Written only by inventory.next_code. No grant and no policy.
create table inventory.code_seq (
  tenant_id   uuid not null,
  kind        text not null,
  last_value  bigint not null default 0,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  primary key (tenant_id, kind),
  constraint code_seq_kind check (kind in ('item', 'store', 'opening')),
  constraint code_seq_non_negative check (last_value >= 0),
  constraint code_seq_never_deleted check (not is_deleted)
);
comment on table inventory.code_seq is
  'Per-hospital counters for item, store, and opening document numbers. A number is never reused.';

-- --------------------------------------------------------------------- item ----
create table inventory.item (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  code             text not null,
  generic_id       uuid references inventory.generic (id),
  brand_name       text not null,
  manufacturer_id  uuid not null references inventory.manufacturer (id),
  item_kind        text not null,
  schedule_code    text,
  hsn_code         text not null,
  base_uom_code    text not null references inventory.uom (code),
  is_cold_chain    boolean not null default false,
  is_high_alert    boolean not null default false,
  is_lasa          boolean not null default false,
  service_item_id  uuid,
  is_active        boolean not null default true,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint item_code_key unique (tenant_id, code),
  constraint item_brand_present check (btrim(brand_name) <> ''),
  constraint item_kind_known check (item_kind in ('drug', 'consumable', 'implant', 'reagent', 'general')),
  constraint item_schedule_known check (schedule_code is null or schedule_code in ('OTC', 'G', 'H', 'H1', 'X', 'NDPS')),
  constraint item_schedule_for_drug check (schedule_code is null or item_kind = 'drug'),
  constraint item_hsn_shape check (hsn_code ~ '^[0-9]{4,8}$'),
  constraint item_drug_has_generic check (item_kind <> 'drug' or generic_id is not null)
);
comment on table inventory.item is
  'Item master. Code is allocated (ITM-0001). Schedule is one code, not a set of flags. service_item_id is a billing id with no cross-schema foreign key.';
comment on column inventory.item.service_item_id is
  'Optional billing.service_item id. No foreign key: billing is another service.';

create table inventory.item_gst (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  item_id        uuid not null references inventory.item (id),
  gst_rate_id    uuid not null references inventory.gst_rate (id),
  effective_from date not null,
  effective_to   date,
  created_on     timestamptz not null default now(),
  created_by     uuid not null,
  updated_on     timestamptz not null default now(),
  updated_by     uuid not null,
  is_deleted     boolean not null default false,
  constraint item_gst_dates check (effective_to is null or effective_to >= effective_from)
);
create unique index item_gst_open_key
  on inventory.item_gst (item_id)
  where effective_to is null and not is_deleted;

create table inventory.item_pack (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  item_id         uuid not null references inventory.item (id),
  uom_code        text not null references inventory.uom (code),
  units_per_pack  bigint not null,
  is_purchase     boolean not null default false,
  is_sale         boolean not null default false,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint item_pack_key unique (item_id, uom_code),
  constraint item_pack_units check (units_per_pack > 1)
);
comment on table inventory.item_pack is
  'How many base units are in a larger pack. The base unit itself is not stored as a pack of 1.';

-- --------------------------------------------------------------------- stores ----
create table inventory.store (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  branch_id         uuid not null,
  code              text not null,
  name              text not null,
  store_kind        text not null,
  drug_licence_no   text,
  licence_valid_to  date,
  is_active         boolean not null default true,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint store_code_key unique (tenant_id, code),
  constraint store_name_present check (btrim(name) <> ''),
  constraint store_kind_known check (store_kind in ('main', 'op_pharmacy', 'ip_pharmacy', 'ward', 'ot', 'lab', 'asset_spares'))
);
comment on table inventory.store is
  'A store at one branch. Code is allocated (STR-0001) and unique for the hospital. branch_id is checked with identity.branch_exists_v1; there is no foreign key to identity.';

create table inventory.store_item_policy (
  store_id      uuid not null references inventory.store (id),
  item_id       uuid not null references inventory.item (id),
  tenant_id     uuid not null,
  min_qty       bigint not null default 0,
  reorder_qty   bigint,
  max_qty       bigint,
  bin_location  text,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  primary key (store_id, item_id),
  constraint store_item_min_non_negative check (min_qty >= 0),
  constraint store_item_reorder_non_negative check (reorder_qty is null or reorder_qty >= 0),
  constraint store_item_max_non_negative check (max_qty is null or max_qty >= 0)
);
comment on table inventory.store_item_policy is
  'Reorder level for one item in one store. min_qty is that level. It is not a column on the item.';

-- --------------------------------------------------------------------- batch / ledger ----
create table inventory.batch (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  item_id      uuid not null references inventory.item (id),
  batch_no     text not null,
  expiry_date  date not null,
  mfg_date     date,
  mrp_paise    bigint not null,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint batch_item_no_expiry_key unique (item_id, batch_no, expiry_date),
  constraint batch_no_present check (btrim(batch_no) <> ''),
  constraint batch_mrp_non_negative check (mrp_paise >= 0),
  constraint batch_expiry_after_mfg check (mfg_date is null or expiry_date > mfg_date)
);
comment on table inventory.batch is
  'One manufacturer batch of an item. Immutable once written. MRP is paise per base unit. Purchase cost is not stored here.';

create table inventory.approval_request (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  action       text not null,
  status       text not null,
  approver_id  uuid not null,
  decided_on   timestamptz not null default now(),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint approval_status_known check (status in ('pending', 'approved', 'rejected'))
);
comment on table inventory.approval_request is
  'Who approved a stock change. Slice 1 inserts approved rows only. The approver is the signed-in user, never a client-supplied id.';

create table inventory.opening_stock (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null,
  store_id              uuid not null references inventory.store (id),
  doc_no                text not null,
  idempotency_key       uuid not null,
  approval_request_id   uuid not null references inventory.approval_request (id),
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint opening_doc_key unique (tenant_id, doc_no),
  constraint opening_idem_key unique (tenant_id, idempotency_key)
);
comment on table inventory.opening_stock is
  'Opening stock document. doc_no is allocated (OPN-0001). Replaying the same idempotency key returns this row.';

create table inventory.opening_stock_line (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  opening_stock_id  uuid not null references inventory.opening_stock (id),
  batch_id          uuid not null references inventory.batch (id),
  qty_base          bigint not null,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint opening_line_qty check (qty_base > 0)
);
comment on table inventory.opening_stock_line is
  'Quantity posted by an opening document. Cost is only on the ledger. MRP is only on the batch.';

create table inventory.stock_ledger (
  id                    uuid primary key default gen_random_uuid(),
  seq                   bigint generated always as identity unique not null,
  tenant_id             uuid not null,
  store_id              uuid not null references inventory.store (id),
  batch_id              uuid not null references inventory.batch (id),
  qty_delta_base        bigint not null,
  movement              text not null,
  unit_cost_paise       bigint not null,
  source_type           text not null,
  source_id             uuid not null,
  reversal_of           uuid references inventory.stock_ledger (id),
  approval_request_id   uuid references inventory.approval_request (id),
  occurred_at           timestamptz not null default now(),
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint stock_ledger_delta_nonzero check (qty_delta_base <> 0),
  constraint stock_ledger_movement check (movement in (
    'grn', 'grn_free', 'purchase_return', 'dispense', 'sale_return',
    'transfer_out', 'transfer_in', 'issue_dept', 'issue_asset',
    'adjust_plus', 'adjust_minus', 'expiry_writeoff', 'audit_variance', 'opening')),
  constraint stock_ledger_cost_non_negative check (unit_cost_paise >= 0),
  constraint stock_ledger_source_key unique (source_type, source_id, batch_id, movement),
  constraint stock_ledger_approval check (
    movement not in ('adjust_plus', 'adjust_minus', 'expiry_writeoff', 'audit_variance', 'opening')
    or approval_request_id is not null),
  constraint stock_ledger_never_deleted check (not is_deleted)
);
comment on table inventory.stock_ledger is
  'The only stock quantity. Append-only. unit_cost_paise is the purchase rate for that movement, in paise per base unit.';
create index stock_ledger_store_batch_idx on inventory.stock_ledger (store_id, batch_id, seq desc);
comment on column inventory.stock_ledger.seq is
  'Append order. Latest purchase rate is the highest seq for a store and batch. id stays a uuid so the audit log can record it.';

create table inventory.stock_balance_cache (
  store_id       uuid not null references inventory.store (id),
  batch_id       uuid not null references inventory.batch (id),
  tenant_id      uuid not null,
  on_hand_base   bigint not null default 0,
  reserved_base  bigint not null default 0,
  created_on     timestamptz not null default now(),
  created_by     uuid not null,
  updated_on     timestamptz not null default now(),
  updated_by     uuid not null,
  is_deleted     boolean not null default false,
  primary key (store_id, batch_id),
  constraint stock_balance_on_hand check (on_hand_base >= 0),
  constraint stock_balance_reserved check (reserved_base >= 0)
);
comment on table inventory.stock_balance_cache is
  'On-hand and reserved quantities. Written only while inventory.balance_write is set, by the ledger trigger or rebuild_stock_balance. Reserved stays 0 in slice 1.';

-- --------------------------------------------------------------------- triggers ----
create or replace function inventory.reject_batch_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'batches are immutable' using errcode = 'P0001';
end;
$$;

create or replace function inventory.reject_ledger_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'stock_ledger is append-only' using errcode = 'P0001';
end;
$$;

create or replace function inventory.guard_balance_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('inventory.balance_write', true) is distinct from '1' then
    raise exception 'stock_balance_cache is maintained by the ledger' using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function inventory.apply_ledger_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_on bigint;
  v_reserved bigint;
begin
  if not exists (
    select 1 from inventory.store s
    where s.id = new.store_id and s.tenant_id = new.tenant_id and not s.is_deleted
  ) or not exists (
    select 1 from inventory.batch b
    where b.id = new.batch_id and b.tenant_id = new.tenant_id and not b.is_deleted
  ) then
    raise exception 'store or batch is not in this hospital' using errcode = '23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.store_id::text || ':' || new.batch_id::text, 0));

  select c.on_hand_base, c.reserved_base
    into v_on, v_reserved
  from inventory.stock_balance_cache c
  where c.store_id = new.store_id and c.batch_id = new.batch_id
  for update;
  v_on := coalesce(v_on, 0);
  v_reserved := coalesce(v_reserved, 0);
  if v_on + new.qty_delta_base < 0 or v_on + new.qty_delta_base < v_reserved then
    raise exception 'stock would go negative' using errcode = 'P0001';
  end if;

  perform set_config('inventory.balance_write', '1', true);
  insert into inventory.stock_balance_cache (store_id, batch_id, tenant_id, on_hand_base, reserved_base)
  values (new.store_id, new.batch_id, new.tenant_id, v_on + new.qty_delta_base, v_reserved)
  on conflict (store_id, batch_id) do update
    set on_hand_base = excluded.on_hand_base,
        reserved_base = excluded.reserved_base;
  perform set_config('inventory.balance_write', '', true);
  return new;
end;
$$;

create or replace function inventory.guard_sale_store_licence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.store_kind in ('op_pharmacy', 'ip_pharmacy')
     and (
       new.drug_licence_no is null
       or btrim(new.drug_licence_no) = ''
       or new.licence_valid_to is null
       or new.licence_valid_to < current_date
     ) then
    raise exception 'a pharmacy needs a current drug licence' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function inventory.guard_pack_uom()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_base text;
begin
  select i.base_uom_code into v_base
  from inventory.item i
  where i.id = new.item_id and i.tenant_id = new.tenant_id;
  if v_base is null then
    raise exception 'pack item was not found' using errcode = '23503';
  end if;
  if new.uom_code = v_base then
    raise exception 'a pack uses a different unit from the base unit' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger uom_audit_columns before insert or update on inventory.uom
  for each row execute function audit.stamp_audit_columns();
create trigger uom_audit_log after insert or update or delete on inventory.uom
  for each row execute function audit.log_row_change();

create trigger manufacturer_audit_columns before insert or update on inventory.manufacturer
  for each row execute function audit.stamp_audit_columns();
create trigger manufacturer_tenant_immutable before update on inventory.manufacturer
  for each row execute function audit.prevent_tenant_change();
create trigger manufacturer_audit_log after insert or update or delete on inventory.manufacturer
  for each row execute function audit.log_row_change();

create trigger generic_audit_columns before insert or update on inventory.generic
  for each row execute function audit.stamp_audit_columns();
create trigger generic_tenant_immutable before update on inventory.generic
  for each row execute function audit.prevent_tenant_change();
create trigger generic_audit_log after insert or update or delete on inventory.generic
  for each row execute function audit.log_row_change();

create trigger gst_rate_audit_columns before insert or update on inventory.gst_rate
  for each row execute function audit.stamp_audit_columns();
create trigger gst_rate_tenant_immutable before update on inventory.gst_rate
  for each row execute function audit.prevent_tenant_change();
create trigger gst_rate_audit_log after insert or update or delete on inventory.gst_rate
  for each row execute function audit.log_row_change();

create trigger code_seq_audit_columns before insert or update on inventory.code_seq
  for each row execute function audit.stamp_audit_columns();
create trigger code_seq_tenant_immutable before update on inventory.code_seq
  for each row execute function audit.prevent_tenant_change();
create trigger code_seq_audit_log after insert or update or delete on inventory.code_seq
  for each row execute function audit.log_row_change();

create trigger item_audit_columns before insert or update on inventory.item
  for each row execute function audit.stamp_audit_columns();
create trigger item_tenant_immutable before update on inventory.item
  for each row execute function audit.prevent_tenant_change();
create trigger item_audit_log after insert or update or delete on inventory.item
  for each row execute function audit.log_row_change();

create trigger item_gst_audit_columns before insert or update on inventory.item_gst
  for each row execute function audit.stamp_audit_columns();
create trigger item_gst_tenant_immutable before update on inventory.item_gst
  for each row execute function audit.prevent_tenant_change();
create trigger item_gst_audit_log after insert or update or delete on inventory.item_gst
  for each row execute function audit.log_row_change();

create trigger item_pack_audit_columns before insert or update on inventory.item_pack
  for each row execute function audit.stamp_audit_columns();
create trigger item_pack_tenant_immutable before update on inventory.item_pack
  for each row execute function audit.prevent_tenant_change();
create trigger item_pack_uom before insert or update on inventory.item_pack
  for each row execute function inventory.guard_pack_uom();
create trigger item_pack_audit_log after insert or update or delete on inventory.item_pack
  for each row execute function audit.log_row_change();

create trigger store_audit_columns before insert or update on inventory.store
  for each row execute function audit.stamp_audit_columns();
create trigger store_tenant_immutable before update on inventory.store
  for each row execute function audit.prevent_tenant_change();
create trigger store_licence before insert or update on inventory.store
  for each row execute function inventory.guard_sale_store_licence();
create trigger store_audit_log after insert or update or delete on inventory.store
  for each row execute function audit.log_row_change();

create trigger store_item_policy_audit_columns before insert or update on inventory.store_item_policy
  for each row execute function audit.stamp_audit_columns();
create trigger store_item_policy_tenant_immutable before update on inventory.store_item_policy
  for each row execute function audit.prevent_tenant_change();
create trigger store_item_policy_audit_log after insert or update or delete on inventory.store_item_policy
  for each row execute function audit.log_row_change();

create trigger batch_audit_columns before insert or update on inventory.batch
  for each row execute function audit.stamp_audit_columns();
create trigger batch_tenant_immutable before update on inventory.batch
  for each row execute function audit.prevent_tenant_change();
create trigger batch_immutable before update or delete on inventory.batch
  for each row execute function inventory.reject_batch_change();
create trigger batch_audit_log after insert or update or delete on inventory.batch
  for each row execute function audit.log_row_change();

create trigger approval_request_audit_columns before insert or update on inventory.approval_request
  for each row execute function audit.stamp_audit_columns();
create trigger approval_request_tenant_immutable before update on inventory.approval_request
  for each row execute function audit.prevent_tenant_change();
create trigger approval_request_audit_log after insert or update or delete on inventory.approval_request
  for each row execute function audit.log_row_change();

create trigger opening_stock_audit_columns before insert or update on inventory.opening_stock
  for each row execute function audit.stamp_audit_columns();
create trigger opening_stock_tenant_immutable before update on inventory.opening_stock
  for each row execute function audit.prevent_tenant_change();
create trigger opening_stock_audit_log after insert or update or delete on inventory.opening_stock
  for each row execute function audit.log_row_change();

create trigger opening_stock_line_audit_columns before insert or update on inventory.opening_stock_line
  for each row execute function audit.stamp_audit_columns();
create trigger opening_stock_line_tenant_immutable before update on inventory.opening_stock_line
  for each row execute function audit.prevent_tenant_change();
create trigger opening_stock_line_audit_log after insert or update or delete on inventory.opening_stock_line
  for each row execute function audit.log_row_change();

create trigger stock_ledger_audit_columns before insert or update on inventory.stock_ledger
  for each row execute function audit.stamp_audit_columns();
create trigger stock_ledger_apply before insert on inventory.stock_ledger
  for each row execute function inventory.apply_ledger_insert();
create trigger stock_ledger_immutable before update or delete on inventory.stock_ledger
  for each row execute function inventory.reject_ledger_change();
create trigger stock_ledger_audit_log after insert or update or delete on inventory.stock_ledger
  for each row execute function audit.log_row_change();

create trigger stock_balance_cache_audit_columns before insert or update on inventory.stock_balance_cache
  for each row execute function audit.stamp_audit_columns();
create trigger stock_balance_cache_guard before insert or update or delete on inventory.stock_balance_cache
  for each row execute function inventory.guard_balance_write();
create trigger stock_balance_cache_tenant_immutable before update on inventory.stock_balance_cache
  for each row execute function audit.prevent_tenant_change();
create trigger stock_balance_cache_audit_log after insert or update or delete on inventory.stock_balance_cache
  for each row execute function audit.log_row_change();

-- Seed after the stamp trigger exists. The stamp fills created_by.
insert into inventory.uom (code, name) values
  ('TAB', 'Tablet'),
  ('CAP', 'Capsule'),
  ('ML', 'Millilitre'),
  ('PC', 'Piece'),
  ('STRIP', 'Strip'),
  ('BOX', 'Box'),
  ('BTL', 'Bottle'),
  ('VIAL', 'Vial'),
  ('AMP', 'Ampoule');

-- --------------------------------------------------------------------- commands ----
create or replace function inventory.bypass_acl()
returns boolean
language sql
stable
set search_path = ''
as $$
  select pg_catalog.pg_get_userbyid(c.relowner) = session_user
  from pg_catalog.pg_class c
  where c.oid = 'inventory.item'::regclass
$$;

create or replace function inventory.assert_permission(p_tenant_id uuid, p_permission text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if inventory.bypass_acl() then
    return;
  end if;
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, p_permission) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
end;
$$;

create or replace function inventory.assert_branch(p_tenant_id uuid, p_branch_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_branch_id is null or not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if not inventory.bypass_acl()
     and p_branch_id not in (select identity.current_branch_ids(p_tenant_id)) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
end;
$$;

create or replace function inventory.reject_supplied(p_body jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_body ? 'code' or p_body ? 'storeCode' or p_body ? 'docNo'
     or p_body ? 'documentNumber' or p_body ? 'id' then
    raise exception 'codes and ids are assigned by the server' using errcode = '22023';
  end if;
end;
$$;

create or replace function inventory.next_code(p_tenant_id uuid, p_kind text, p_prefix text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n bigint;
begin
  insert into inventory.code_seq (tenant_id, kind, last_value)
  values (p_tenant_id, p_kind, 1)
  on conflict (tenant_id, kind) do update
    set last_value = inventory.code_seq.last_value + 1
  returning last_value into v_n;
  return p_prefix || '-' || pg_catalog.lpad(v_n::text, 4, '0');
end;
$$;

create or replace function inventory.item_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', i.id,
    'code', i.code,
    'itemKind', i.item_kind,
    'brandName', i.brand_name,
    'genericName', g.name,
    'strength', nullif(g.strength, ''),
    'dosageForm', nullif(g.dosage_form, ''),
    'route', g.route,
    'manufacturerName', m.name,
    'scheduleCode', i.schedule_code,
    'hsnCode', i.hsn_code,
    'gstRateBp', gr.rate_bp,
    'baseUomCode', i.base_uom_code,
    'isColdChain', i.is_cold_chain,
    'isHighAlert', i.is_high_alert,
    'isLasa', i.is_lasa,
    'isActive', i.is_active,
    'packs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uomCode', p.uom_code,
        'unitsPerPack', p.units_per_pack,
        'isPurchase', p.is_purchase,
        'isSale', p.is_sale
      ) order by p.uom_code)
      from inventory.item_pack p
      where p.item_id = i.id and not p.is_deleted
    ), '[]'::jsonb)
  )
  from inventory.item i
  join inventory.manufacturer m on m.id = i.manufacturer_id
  left join inventory.generic g on g.id = i.generic_id
  left join lateral (
    select r.rate_bp
    from inventory.item_gst ig
    join inventory.gst_rate r on r.id = ig.gst_rate_id
    where ig.item_id = i.id and not ig.is_deleted and ig.effective_to is null
    order by ig.effective_from desc
    limit 1
  ) gr on true
  where i.id = p_id and not i.is_deleted
$$;

create or replace function inventory.store_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'code', s.code,
    'branchId', s.branch_id,
    'name', s.name,
    'storeKind', s.store_kind,
    'drugLicenceNo', s.drug_licence_no,
    'licenceValidTo', s.licence_valid_to,
    'isActive', s.is_active
  )
  from inventory.store s
  where s.id = p_id and not s.is_deleted
$$;

create or replace function inventory.opening_document(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', o.id,
    'docNo', o.doc_no,
    'storeId', o.store_id,
    'approvalRequestId', o.approval_request_id,
    'approverId', a.approver_id,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id,
        'batchId', l.batch_id,
        'itemId', b.item_id,
        'batchNo', b.batch_no,
        'expiryDate', b.expiry_date,
        'mrpPaise', b.mrp_paise,
        'qtyBase', l.qty_base
      ) order by l.created_on)
      from inventory.opening_stock_line l
      join inventory.batch b on b.id = l.batch_id
      where l.opening_stock_id = o.id and not l.is_deleted
    ), '[]'::jsonb)
  )
  from inventory.opening_stock o
  join inventory.approval_request a on a.id = o.approval_request_id
  where o.id = p_id and not o.is_deleted
$$;

create or replace function inventory.create_item(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  values (p_tenant_id, v_item, v_gst_id, current_date);

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
$$;

create or replace function inventory.list_items(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(inventory.item_json(i.id) order by i.code)
      from inventory.item i
      where i.tenant_id = p_tenant_id and not i.is_deleted
    ), '[]'::jsonb),
    'uoms', coalesce((
      select jsonb_agg(jsonb_build_object('code', u.code, 'name', u.name) order by u.code)
      from inventory.uom u
      where not u.is_deleted
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function inventory.create_store(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch uuid := nullif(p_body ->> 'branchId', '')::uuid;
  v_name text := btrim(p_body ->> 'name');
  v_kind text := p_body ->> 'storeKind';
  v_licence text := nullif(btrim(p_body ->> 'drugLicenceNo'), '');
  v_until date := nullif(p_body ->> 'licenceValidTo', '')::date;
  v_id uuid;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.catalog');
  perform inventory.reject_supplied(p_body);
  perform inventory.assert_branch(p_tenant_id, v_branch);
  if v_name is null or v_name = '' then
    raise exception 'name is required' using errcode = '22023';
  end if;
  if v_kind is null or v_kind not in ('main', 'op_pharmacy', 'ip_pharmacy', 'ward', 'ot', 'lab', 'asset_spares') then
    raise exception 'storeKind is not a known store type' using errcode = '22023';
  end if;
  insert into inventory.store (tenant_id, branch_id, code, name, store_kind, drug_licence_no, licence_valid_to)
  values (p_tenant_id, v_branch, inventory.next_code(p_tenant_id, 'store', 'STR'), v_name, v_kind, v_licence, v_until)
  returning id into v_id;
  return inventory.store_json(v_id);
end;
$$;

create or replace function inventory.list_stores(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  return coalesce((
    select jsonb_agg(inventory.store_json(s.id) order by s.code)
    from inventory.store s
    where s.tenant_id = p_tenant_id
      and not s.is_deleted
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ), '[]'::jsonb);
end;
$$;

create or replace function inventory.post_opening_stock(p_tenant_id uuid, p_key uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing uuid;
  v_store uuid := nullif(p_body ->> 'storeId', '')::uuid;
  v_branch uuid;
  v_actor uuid;
  v_approval uuid;
  v_doc uuid;
  v_line jsonb;
  v_item uuid;
  v_batch_no text;
  v_expiry date;
  v_mfg date;
  v_mrp bigint;
  v_cost bigint;
  v_qty bigint;
  v_batch uuid;
  v_known_mrp bigint;
  v_line_id uuid;
begin
  if p_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  perform inventory.assert_permission(p_tenant_id, 'inventory.opening');
  perform inventory.assert_permission(p_tenant_id, 'inventory.approve');
  perform inventory.reject_supplied(p_body);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_tenant_id::text || ':' || p_key::text, 0));
  select o.id into v_existing
  from inventory.opening_stock o
  where o.tenant_id = p_tenant_id and o.idempotency_key = p_key and not o.is_deleted;
  if v_existing is not null then
    return inventory.opening_document(v_existing);
  end if;

  if not exists (
    select 1 from inventory.store s
    where s.id = v_store and s.tenant_id = p_tenant_id and not s.is_deleted
  ) then
    raise exception 'store not found' using errcode = 'P0002';
  end if;
  select s.branch_id into v_branch from inventory.store s where s.id = v_store;
  perform inventory.assert_branch(p_tenant_id, v_branch);
  if jsonb_typeof(p_body -> 'lines') is distinct from 'array'
     or jsonb_array_length(p_body -> 'lines') < 1 then
    raise exception 'at least one line is required' using errcode = '22023';
  end if;

  v_actor := audit.session_actor_id();
  if v_actor is null then
    raise exception 'an approver must be signed in' using errcode = '42501';
  end if;
  insert into inventory.approval_request (tenant_id, action, status, approver_id)
  values (p_tenant_id, 'opening', 'approved', v_actor)
  returning id into v_approval;
  insert into inventory.opening_stock (tenant_id, store_id, doc_no, idempotency_key, approval_request_id)
  values (p_tenant_id, v_store, inventory.next_code(p_tenant_id, 'opening', 'OPN'), p_key, v_approval)
  returning id into v_doc;

  for v_line in select value from jsonb_array_elements(p_body -> 'lines')
  loop
    v_item := nullif(v_line ->> 'itemId', '')::uuid;
    v_batch_no := btrim(v_line ->> 'batchNo');
    v_expiry := nullif(v_line ->> 'expiryDate', '')::date;
    v_mfg := nullif(v_line ->> 'mfgDate', '')::date;
    if not exists (
      select 1 from inventory.item i
      where i.id = v_item and i.tenant_id = p_tenant_id and not i.is_deleted
    ) then
      raise exception 'item not found' using errcode = 'P0002';
    end if;
    if v_batch_no is null or v_batch_no = '' or v_expiry is null then
      raise exception 'batchNo and expiryDate are required' using errcode = '22023';
    end if;
    if v_mfg is not null and v_expiry <= v_mfg then
      raise exception 'expiryDate must be after mfgDate' using errcode = '22023';
    end if;
    if jsonb_typeof(v_line -> 'mrpPaise') is distinct from 'number'
       or jsonb_typeof(v_line -> 'purchaseRatePaise') is distinct from 'number'
       or jsonb_typeof(v_line -> 'qtyBase') is distinct from 'number' then
      raise exception 'mrpPaise, purchaseRatePaise, and qtyBase are required' using errcode = '22023';
    end if;
    v_mrp := (v_line ->> 'mrpPaise')::bigint;
    v_cost := (v_line ->> 'purchaseRatePaise')::bigint;
    v_qty := (v_line ->> 'qtyBase')::bigint;
    if v_mrp < 0 or v_cost < 0 or v_qty <= 0 then
      raise exception 'money cannot be negative and quantity must be at least 1' using errcode = '22023';
    end if;

    select b.id, b.mrp_paise into v_batch, v_known_mrp
    from inventory.batch b
    where b.item_id = v_item and b.batch_no = v_batch_no and b.expiry_date = v_expiry and not b.is_deleted;
    if v_batch is not null then
      if v_known_mrp is distinct from v_mrp then
        raise exception 'this batch is already recorded at a different MRP' using errcode = '22023';
      end if;
    else
      insert into inventory.batch (tenant_id, item_id, batch_no, expiry_date, mfg_date, mrp_paise)
      values (p_tenant_id, v_item, v_batch_no, v_expiry, v_mfg, v_mrp)
      returning id into v_batch;
    end if;

    insert into inventory.opening_stock_line (tenant_id, opening_stock_id, batch_id, qty_base)
    values (p_tenant_id, v_doc, v_batch, v_qty)
    returning id into v_line_id;
    insert into inventory.stock_ledger (
      tenant_id, store_id, batch_id, qty_delta_base, movement, unit_cost_paise,
      source_type, source_id, approval_request_id
    ) values (
      p_tenant_id, v_store, v_batch, v_qty, 'opening', v_cost,
      'opening_line', v_line_id, v_approval
    );
  end loop;

  return inventory.opening_document(v_doc);
end;
$$;

create or replace function inventory.stock_on_hand(p_tenant_id uuid, p_store_id uuid, p_item_id uuid)
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
    where c.tenant_id = p_tenant_id
      and c.on_hand_base > 0
      and not s.is_deleted
      and not b.is_deleted
      and not i.is_deleted
      and (p_store_id is null or c.store_id = p_store_id)
      and (p_item_id is null or b.item_id = p_item_id)
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ), '[]'::jsonb);
end;
$$;

create or replace function inventory.rebuild_stock_balance(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.approve');
  perform set_config('inventory.balance_write', '1', true);
  delete from inventory.stock_balance_cache c
  where c.tenant_id = p_tenant_id
    and (inventory.bypass_acl() or c.store_id in (
      select s.id from inventory.store s
      where s.tenant_id = p_tenant_id
        and s.branch_id in (select identity.current_branch_ids(p_tenant_id))
    ));
  insert into inventory.stock_balance_cache (store_id, batch_id, tenant_id, on_hand_base, reserved_base)
  select l.store_id, l.batch_id, l.tenant_id, sum(l.qty_delta_base), 0
  from inventory.stock_ledger l
  join inventory.store s on s.id = l.store_id
  where l.tenant_id = p_tenant_id
    and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  group by l.store_id, l.batch_id, l.tenant_id
  having sum(l.qty_delta_base) > 0;
  perform set_config('inventory.balance_write', '', true);
end;
$$;

-- cross-schema: approved
create or replace function inventory.fefo_pick_v1(
  p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_qty bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_left bigint := p_qty;
  v_picked bigint := 0;
  v_take bigint;
  v_row record;
  v_batches jsonb := '[]'::jsonb;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  if not exists (
    select 1 from inventory.store s
    where s.id = p_store_id and s.tenant_id = p_tenant_id and not s.is_deleted
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ) then
    raise exception 'store not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from inventory.item i
    where i.id = p_item_id and i.tenant_id = p_tenant_id and not i.is_deleted
  ) then
    raise exception 'item not found' using errcode = 'P0002';
  end if;
  if p_qty is not null and p_qty <= 0 then
    raise exception 'qty must be at least 1' using errcode = '22023';
  end if;

  for v_row in
    select b.id, b.batch_no, b.expiry_date, c.on_hand_base
    from inventory.stock_balance_cache c
    join inventory.batch b on b.id = c.batch_id
    where c.tenant_id = p_tenant_id
      and c.store_id = p_store_id
      and b.item_id = p_item_id
      and c.on_hand_base > 0
      and b.expiry_date >= current_date
      and not b.is_deleted
    order by b.expiry_date, b.id
  loop
    if p_qty is null then
      v_take := v_row.on_hand_base;
    else
      exit when v_left <= 0;
      v_take := least(v_row.on_hand_base, v_left);
      v_left := v_left - v_take;
    end if;
    v_picked := v_picked + v_take;
    v_batches := v_batches || jsonb_build_array(jsonb_build_object(
      'batchId', v_row.id,
      'batchNo', v_row.batch_no,
      'expiryDate', v_row.expiry_date,
      'onHandBase', v_row.on_hand_base,
      'pickBase', v_take
    ));
  end loop;

  return jsonb_build_object(
    'requestedBase', p_qty,
    'pickedBase', v_picked,
    'shortBase', case when p_qty is null then 0 else greatest(p_qty - v_picked, 0) end,
    'batches', v_batches
  );
end;
$$;

comment on function inventory.fefo_pick_v1(uuid, uuid, uuid, bigint) is
  'FEFO lookup for a later pharmacy issue. Does not reserve or change stock. Owned by inventory; not granted to other services yet.';

-- --------------------------------------------------------------------- grants / RLS ----
alter table inventory.uom enable row level security;
alter table inventory.manufacturer enable row level security;
alter table inventory.generic enable row level security;
alter table inventory.gst_rate enable row level security;
alter table inventory.code_seq enable row level security;
alter table inventory.item enable row level security;
alter table inventory.item_gst enable row level security;
alter table inventory.item_pack enable row level security;
alter table inventory.store enable row level security;
alter table inventory.store_item_policy enable row level security;
alter table inventory.batch enable row level security;
alter table inventory.approval_request enable row level security;
alter table inventory.opening_stock enable row level security;
alter table inventory.opening_stock_line enable row level security;
alter table inventory.stock_ledger enable row level security;
alter table inventory.stock_balance_cache enable row level security;

revoke all on all tables in schema inventory from public, anon, authenticated,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing, hms_api;
revoke all on inventory.code_seq from hms_svc_inventory;

grant select on
  inventory.uom,
  inventory.manufacturer,
  inventory.generic,
  inventory.gst_rate,
  inventory.item,
  inventory.item_gst,
  inventory.item_pack,
  inventory.store,
  inventory.store_item_policy,
  inventory.batch,
  inventory.approval_request,
  inventory.opening_stock,
  inventory.opening_stock_line,
  inventory.stock_ledger,
  inventory.stock_balance_cache
to hms_svc_inventory;

revoke delete on all tables in schema inventory from hms_svc_inventory;

create policy uom_read on inventory.uom
  for select to hms_svc_inventory using (true);

create policy manufacturer_tenant on inventory.manufacturer
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy generic_tenant on inventory.generic
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy gst_rate_tenant on inventory.gst_rate
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy item_tenant on inventory.item
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy item_gst_tenant on inventory.item_gst
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy item_pack_tenant on inventory.item_pack
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy store_branch on inventory.store
  for select to hms_svc_inventory
  using (
    tenant_id in (select identity.current_tenant_ids())
    and branch_id in (select identity.current_branch_ids(tenant_id))
  );

create policy store_item_policy_tenant on inventory.store_item_policy
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy batch_tenant on inventory.batch
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy approval_request_tenant on inventory.approval_request
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy opening_stock_branch on inventory.opening_stock
  for select to hms_svc_inventory
  using (
    tenant_id in (select identity.current_tenant_ids())
    and store_id in (
      select s.id from inventory.store s
      where s.branch_id in (select identity.current_branch_ids(opening_stock.tenant_id))
    )
  );

create policy opening_stock_line_tenant on inventory.opening_stock_line
  for select to hms_svc_inventory
  using (tenant_id in (select identity.current_tenant_ids()));

create policy stock_ledger_branch on inventory.stock_ledger
  for select to hms_svc_inventory
  using (
    tenant_id in (select identity.current_tenant_ids())
    and store_id in (
      select s.id from inventory.store s
      where s.branch_id in (select identity.current_branch_ids(stock_ledger.tenant_id))
    )
  );

create policy stock_balance_branch on inventory.stock_balance_cache
  for select to hms_svc_inventory
  using (
    tenant_id in (select identity.current_tenant_ids())
    and store_id in (
      select s.id from inventory.store s
      where s.branch_id in (select identity.current_branch_ids(stock_balance_cache.tenant_id))
    )
  );

grant usage on schema identity, auth, audit to hms_svc_inventory;
grant execute on function auth.uid() to hms_svc_inventory;
grant execute on function auth.jwt() to hms_svc_inventory;
grant execute on function audit.session_actor_id() to hms_svc_inventory;
grant execute on function identity.current_tenant_ids() to hms_svc_inventory;
grant execute on function identity.current_branch_ids(uuid) to hms_svc_inventory;
grant execute on function identity.has_tenant_permission(uuid, text) to hms_svc_inventory;
grant execute on function identity.branch_exists_v1(uuid, uuid) to hms_svc_inventory;
grant execute on function identity.my_tenant_grant_v1(uuid) to hms_svc_inventory;
grant execute on function identity.my_active_context() to hms_svc_inventory;

revoke all on all functions in schema inventory from public, anon, authenticated,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing, hms_api;
grant execute on function inventory.create_item(uuid, jsonb) to hms_svc_inventory, service_role;
grant execute on function inventory.list_items(uuid) to hms_svc_inventory, service_role;
grant execute on function inventory.create_store(uuid, jsonb) to hms_svc_inventory, service_role;
grant execute on function inventory.list_stores(uuid) to hms_svc_inventory, service_role;
grant execute on function inventory.post_opening_stock(uuid, uuid, jsonb) to hms_svc_inventory, service_role;
grant execute on function inventory.stock_on_hand(uuid, uuid, uuid) to hms_svc_inventory, service_role;
grant execute on function inventory.rebuild_stock_balance(uuid) to hms_svc_inventory, service_role;
grant execute on function inventory.fefo_pick_v1(uuid, uuid, uuid, bigint) to hms_svc_inventory, service_role;
