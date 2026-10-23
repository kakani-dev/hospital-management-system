-- cross-schema: approved (RLS uses identity.current_tenant_ids. Audit stamps and the row log
-- use audit.stamp_audit_columns, audit.prevent_tenant_change and audit.log_row_change.
-- No table reads outside billing.)
-- Service codes and category tax defaults.
-- A code is a category prefix plus one per-tenant sequence (PROC-0001, then CERT-0002).
-- The sequence lives in billing.service_code_seq and is written only by billing.allocate_service_code.
-- Tax is a reference: billing.category_tax_default.tax_code_id points at billing.tax_code.
-- SAC and the rate stay on the tax code. They are not copied onto the category or the item.
--
-- Indian OP assumptions (hospitals override under Advanced):
--   Clinical categories (consultation, procedure, lab, imaging, room, package) default to the
--   existing EXEMPT code, SAC 9993, rate 0. That is healthcare by a clinical establishment
--   (Entry 74, Notification 12/2017). Room rent is treated as exempt healthcare accommodation.
--   Non-clinical categories (consumable, other) default to GST18, SAC 9997, 18% (1800 basis points).
--   SAC 9997 ("other services") is a placeholder, not a ruling that every certificate is 9997.
--   Consumables sold as goods may need an HSN at 5% or 12%. Pharmacy HSN is out of scope.
-- Existing item codes (CONSULT, and any code a hospital already saved) are left as they are.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

-- ------------------------------------------------------------------ prefix catalog ----
-- Global, not per tenant: the eight service categories and the readable code prefix for each.
-- Dressings are procedures (PROC). Certificates and other non-clinical items are CERT.
create table billing.service_category (
  category    text primary key,
  code_prefix text not null,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint service_category_known check (category in (
    'consultation', 'procedure', 'lab', 'imaging', 'consumable', 'room', 'package', 'other')),
  constraint service_category_prefix_key unique (code_prefix),
  constraint service_category_prefix_shape check (code_prefix ~ '^[A-Z]{2,8}$')
);
comment on table billing.service_category is
  'Category to code prefix. Shared by every tenant. PROC, CERT and the rest are not copied onto items.';

-- ------------------------------------------------------------------ per-tenant counter ----
-- One row per tenant, not per category: PROC-0001 then CERT-0002 share the number.
-- No grant and no policy. billing.allocate_service_code is the only writer.
create table billing.service_code_seq (
  tenant_id   uuid primary key,
  last_value  bigint not null default 0,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint service_code_seq_non_negative check (last_value >= 0),
  constraint service_code_seq_never_deleted check (not is_deleted)
);
comment on table billing.service_code_seq is
  'Per-tenant service-code counter. Row-locked by allocate_service_code. Gaps only if a transaction rolls back.';

-- ------------------------------------------------------------------ category -> tax ----
create table billing.category_tax_default (
  tenant_id    uuid not null,
  category     text not null references billing.service_category (category),
  tax_code_id  uuid not null references billing.tax_code (id),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  primary key (tenant_id, category)
);
comment on table billing.category_tax_default is
  'Which tax code a category starts on. The SAC and rate stay on billing.tax_code.';

-- ------------------------------------------------------------------ audit + RLS ----
create trigger service_category_audit_columns before insert or update on billing.service_category
  for each row execute function audit.stamp_audit_columns();
create trigger service_category_audit_log after insert or update or delete on billing.service_category
  for each row execute function audit.log_row_change();

create trigger service_code_seq_audit_columns before insert or update on billing.service_code_seq
  for each row execute function audit.stamp_audit_columns();
create trigger service_code_seq_tenant_immutable before update on billing.service_code_seq
  for each row execute function audit.prevent_tenant_change();
create trigger service_code_seq_audit_log after insert or update or delete on billing.service_code_seq
  for each row execute function audit.log_row_change();

create trigger category_tax_default_audit_columns before insert or update on billing.category_tax_default
  for each row execute function audit.stamp_audit_columns();
create trigger category_tax_default_tenant_immutable before update on billing.category_tax_default
  for each row execute function audit.prevent_tenant_change();
create trigger category_tax_default_audit_log after insert or update or delete on billing.category_tax_default
  for each row execute function audit.log_row_change();

alter table billing.service_category enable row level security;
alter table billing.service_code_seq enable row level security;
alter table billing.category_tax_default enable row level security;

revoke all on billing.service_category from public, anon, authenticated;
revoke all on billing.service_code_seq from public, anon, authenticated, hms_svc_billing;
revoke all on billing.category_tax_default from public, anon, authenticated;

grant select on billing.service_category to hms_svc_billing;
create policy service_category_read on billing.service_category
  for select to hms_svc_billing using (true);

grant select, insert, update on billing.category_tax_default to hms_svc_billing;
create policy category_tax_default_tenant on billing.category_tax_default
  for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));

-- Triggers are already in place, so the stamp fills created_by.
insert into billing.service_category (category, code_prefix) values
  ('consultation', 'CONS'),
  ('procedure', 'PROC'),
  ('lab', 'LAB'),
  ('imaging', 'IMG'),
  ('consumable', 'MAT'),
  ('room', 'ROOM'),
  ('package', 'PKG'),
  ('other', 'CERT');

-- Seed past any PREFIX-NUMBER already stored, including deleted rows (a code is never reused).
-- CONSULT and DRESS do not match, so the first generated code is still PREFIX-0001.
insert into billing.service_code_seq (tenant_id, last_value)
select si.tenant_id, max(substring(si.code from '^[A-Za-z]+-([0-9]{1,18})$')::bigint)
from billing.service_item si
where si.code ~ '^[A-Za-z]+-[0-9]{1,18}$'
group by si.tenant_id;

-- ------------------------------------------------------- category tax seed ----
create or replace function billing.ensure_category_defaults(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_exempt uuid;
  v_gst uuid;
begin
  select id into v_exempt from billing.tax_code
  where tenant_id = p_tenant_id and code = 'EXEMPT' and not is_deleted
  order by effective_from desc
  limit 1;
  if v_exempt is null then
    insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
    values (p_tenant_id, 'EXEMPT', '9993', true, 0, date '2017-07-01')
    returning id into v_exempt;
  end if;

  select id into v_gst from billing.tax_code
  where tenant_id = p_tenant_id and code = 'GST18' and not is_deleted
  order by effective_from desc
  limit 1;
  if v_gst is null then
    insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
    values (p_tenant_id, 'GST18', '9997', false, 1800, date '2017-07-01')
    returning id into v_gst;
  end if;

  insert into billing.category_tax_default (tenant_id, category, tax_code_id)
  select p_tenant_id, c.category,
         case when c.category in ('consumable', 'other') then v_gst else v_exempt end
  from billing.service_category c
  on conflict (tenant_id, category) do nothing;
end;
$$;

comment on function billing.ensure_category_defaults(uuid) is
  'Ensures EXEMPT (SAC 9993) and GST18 (SAC 9997, 18%) and one category_tax_default row per category.';

-- Same seed path as the catalog. Category defaults are filled once EXEMPT exists.
create or replace function billing.ensure_defaults(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tax uuid;
  v_item uuid;
  v_list uuid;
begin
  select id into v_tax from billing.tax_code
  where tenant_id = p_tenant_id and code = 'EXEMPT' and not is_deleted
  order by effective_from desc limit 1;
  if v_tax is null then
    insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
    values (p_tenant_id, 'EXEMPT', '9993', true, 0, date '2017-07-01')
    returning id into v_tax;
  end if;
  perform billing.ensure_category_defaults(p_tenant_id);
  select id into v_item from billing.service_item
  where tenant_id = p_tenant_id and code = 'CONSULT' and not is_deleted;
  if v_item is null then
    insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
    values (p_tenant_id, 'CONSULT', 'OP consultation', 'consultation', v_tax)
    returning id into v_item;
  end if;
  select id into v_list from billing.price_list
  where tenant_id = p_tenant_id and branch_id is null and name = 'Standard' and not is_deleted;
  if v_list is null then
    insert into billing.price_list (tenant_id, name)
    values (p_tenant_id, 'Standard')
    returning id into v_list;
  end if;
  if not exists (
    select 1 from billing.price_list_item
    where price_list_id = v_list and service_item_id = v_item and practitioner_id is null and not is_deleted
  ) then
    insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
    values (p_tenant_id, v_list, v_item, 50000, date '2017-07-01');
  end if;
  insert into billing.approval_policy (tenant_id, action, role, max_amount_paise, max_percent_bp)
  select p_tenant_id, v.action, v.role, v.amount, v.percent
  from (values
    ('discount', 'receptionist', 20000::bigint, 500),
    ('discount', 'billing', 20000::bigint, 500),
    ('discount', 'supervisor', 200000::bigint, 2000),
    ('discount', 'manager', null::bigint, null::integer),
    ('refund', 'receptionist', 0::bigint, null::integer),
    ('refund', 'billing', 0::bigint, null::integer),
    ('refund', 'supervisor', null::bigint, null::integer),
    ('refund', 'manager', null::bigint, null::integer),
    ('cash_variance', 'receptionist', 0::bigint, null::integer),
    ('cash_variance', 'billing', 0::bigint, null::integer),
    ('cash_variance', 'supervisor', 100000::bigint, null::integer),
    ('cash_variance', 'manager', null::bigint, null::integer),
    ('write_off', 'manager', null::bigint, null::integer),
    ('cancel_receipt', 'manager', null::bigint, null::integer)
  ) as v(action, role, amount, percent)
  where not exists (
    select 1 from billing.approval_policy p
    where p.tenant_id = p_tenant_id and p.action = v.action and p.role = v.role and not p.is_deleted);
end;
$$;

-- ------------------------------------------------------- code allocation ----
-- Security definer so the counter table needs no grant. The row lock is the concurrency control.
create or replace function billing.allocate_service_code(p_tenant_id uuid, p_category text, p_custom text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_custom text := nullif(btrim(coalesce(p_custom, '')), '');
  v_prefix text;
  v_n bigint;
  v_suffix bigint;
  v_code text;
begin
  -- Direct check: assert_permission treats the table owner as a bypass, and this function
  -- is security definer so it runs as that owner. The JWT still identifies the caller.
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, 'billing.pricelist_manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select code_prefix into v_prefix from billing.service_category where category = p_category;
  if v_prefix is null then
    raise exception 'category is not recognised' using errcode = '22023';
  end if;

  if v_custom is not null then
    if length(v_custom) > 40 then
      raise exception 'code is too long' using errcode = '22023';
    end if;
    if exists (
      select 1 from billing.service_item
      where tenant_id = p_tenant_id and code = v_custom
    ) then
      raise exception 'that code is already in the price list' using errcode = '23505';
    end if;
    -- A custom PROC-0009 must move the shared counter so the next generated code cannot collide.
    if v_custom ~* '^[A-Za-z]+-[0-9]{1,18}$' then
      v_suffix := substring(v_custom from '([0-9]{1,18})$')::bigint;
      insert into billing.service_code_seq as s (tenant_id, last_value)
      values (p_tenant_id, v_suffix)
      on conflict (tenant_id) do update
        set last_value = greatest(s.last_value, excluded.last_value)
        where excluded.last_value > s.last_value;
    end if;
    return v_custom;
  end if;

  loop
    insert into billing.service_code_seq as s (tenant_id, last_value)
    values (p_tenant_id, 1)
    on conflict (tenant_id) do update
      set last_value = s.last_value + 1
    returning s.last_value into v_n;

    v_code := v_prefix || '-' || case
      when v_n <= 9999 then pg_catalog.lpad(v_n::text, 4, '0')
      else v_n::text
    end;
    if length(v_code) > 40 or v_n > 999999 then
      raise exception 'could not allocate a service code' using errcode = '22023';
    end if;
    exit when not exists (
      select 1 from billing.service_item
      where tenant_id = p_tenant_id and code = v_code
    );
  end loop;
  return v_code;
end;
$$;

comment on function billing.allocate_service_code(uuid, text, text) is
  'Next PREFIX-0001 code, or the custom code when one is supplied. Custom codes are not rewritten.';

-- Code is immutable after create. Omit taxCodeId to use the category default.
-- A deactivate that sends only id and isActive does not change the tax.
create or replace function billing.upsert_service_item(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_body ->> 'id', '')::uuid;
  v_code text := nullif(btrim(p_body ->> 'code'), '');
  v_name text := nullif(btrim(p_body ->> 'name'), '');
  v_category text := nullif(btrim(p_body ->> 'category'), '');
  v_tax uuid := nullif(p_body ->> 'taxCodeId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.ensure_defaults(p_tenant_id);

  if v_id is null then
    if v_name is null or length(v_name) > 160 then
      raise exception 'name is required' using errcode = '22023';
    end if;
    if v_category is null or not exists (
      select 1 from billing.service_category where category = v_category
    ) then
      raise exception 'category is not recognised' using errcode = '22023';
    end if;
    if v_tax is null then
      select tax_code_id into v_tax from billing.category_tax_default
      where tenant_id = p_tenant_id and category = v_category and not is_deleted;
    elsif not exists (
      select 1 from billing.tax_code
      where id = v_tax and tenant_id = p_tenant_id and not is_deleted
    ) then
      raise exception 'tax code not found' using errcode = 'P0002';
    end if;
    if v_tax is null then
      raise exception 'tax code not found' using errcode = 'P0002';
    end if;
    v_code := billing.allocate_service_code(p_tenant_id, v_category, v_code);
    insert into billing.service_item (tenant_id, code, name, category, tax_code_id, is_stock_tracked)
    values (
      p_tenant_id, v_code, v_name, v_category, v_tax,
      coalesce((p_body ->> 'isStockTracked')::boolean, false))
    returning id into v_id;
  else
    if v_tax is not null and not exists (
      select 1 from billing.tax_code
      where id = v_tax and tenant_id = p_tenant_id and not is_deleted
    ) then
      raise exception 'tax code not found' using errcode = 'P0002';
    end if;
    if v_category is not null and not exists (
      select 1 from billing.service_category where category = v_category
    ) then
      raise exception 'category is not recognised' using errcode = '22023';
    end if;
    if v_name is not null and length(v_name) > 160 then
      raise exception 'name is required' using errcode = '22023';
    end if;
    -- Category without a tax uses that category's default. Neither field means "leave the tax".
    if v_tax is null and v_category is not null then
      select tax_code_id into v_tax from billing.category_tax_default
      where tenant_id = p_tenant_id and category = v_category and not is_deleted;
    end if;
    update billing.service_item
    set name = coalesce(v_name, name),
        category = coalesce(v_category, category),
        tax_code_id = coalesce(v_tax, tax_code_id),
        is_active = coalesce((p_body ->> 'isActive')::boolean, is_active),
        is_stock_tracked = coalesce((p_body ->> 'isStockTracked')::boolean, is_stock_tracked)
    where id = v_id and tenant_id = p_tenant_id and not is_deleted;
    if not found then
      raise exception 'service item not found' using errcode = 'P0002';
    end if;
    select code into v_code from billing.service_item where id = v_id;
  end if;
  return jsonb_build_object('id', v_id, 'code', v_code);
end;
$$;

create or replace function billing.list_category_defaults(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.ensure_category_defaults(p_tenant_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'category', d.category,
      'codePrefix', c.code_prefix,
      'taxCodeId', d.tax_code_id,
      'sacHsnCode', tc.sac_hsn_code,
      'rateBp', tc.rate_bp,
      'isExempt', tc.is_exempt
    ) order by d.category)
    from billing.category_tax_default d
    join billing.service_category c on c.category = d.category
    join billing.tax_code tc on tc.id = d.tax_code_id
    where d.tenant_id = p_tenant_id and not d.is_deleted
  ), '[]'::jsonb);
end;
$$;

comment on function billing.list_category_defaults(uuid) is
  'Prefix and default tax for each category. SAC and rate are read from the tax code.';

-- Code and SAC are optional. A blank code is generated on apply (a dry run does not take a number).
-- A blank SAC uses the category default, not SAC 9993. An explicit SAC still picks a tax code by SAC.
create or replace function billing.import_prices(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_dry boolean := coalesce((p_body ->> 'dryRun')::boolean, true);
  v_row jsonb;
  v_results jsonb := '[]'::jsonb;
  v_index integer := 0;
  v_client integer;
  v_status text;
  v_detail text;
  v_item_action text;
  v_code text;
  v_name text;
  v_category text;
  v_sac text;
  v_name_key text;
  v_plan_key text;
  v_paise bigint;
  v_from date;
  v_to date;
  v_branch uuid;
  v_prac uuid;
  v_item uuid;
  v_active boolean;
  v_tax uuid;
  v_list uuid;
  v_nil uuid := '00000000-0000-0000-0000-000000000000';
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.ensure_defaults(p_tenant_id);
  if jsonb_typeof(p_body -> 'rows') is distinct from 'array' then
    raise exception 'rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_body -> 'rows') > 500 then
    raise exception 'import at most 500 rows' using errcode = '22023';
  end if;

  create temporary table if not exists pg_temp.price_import_plan (
    branch_key uuid not null,
    item_key text not null,
    practitioner_key uuid not null,
    active_range daterange not null
  ) on commit drop;
  delete from pg_temp.price_import_plan;

  create temporary table if not exists pg_temp.price_import_new (
    name_key text primary key,
    item_id uuid not null,
    code text not null
  ) on commit drop;
  delete from pg_temp.price_import_new;

  for v_row in select value from jsonb_array_elements(p_body -> 'rows') as t(value)
  loop
    v_index := v_index + 1;
    v_status := 'ready';
    v_detail := null;
    v_item_action := null;
    v_code := null;
    v_name := null;
    v_category := null;
    v_sac := null;
    v_name_key := null;
    v_plan_key := null;
    v_paise := null;
    v_from := null;
    v_to := null;
    v_branch := null;
    v_prac := null;
    v_item := null;
    v_active := null;
    v_tax := null;
    v_list := null;
    v_client := v_index;

    begin
      if (v_row ->> 'clientIndex') ~ '^[0-9]+$' then
        v_client := (v_row ->> 'clientIndex')::integer;
      end if;
      v_code := nullif(btrim(v_row ->> 'code'), '');
      v_name := nullif(btrim(v_row ->> 'name'), '');
      v_category := coalesce(nullif(btrim(v_row ->> 'category'), ''), 'other');
      v_sac := nullif(btrim(v_row ->> 'sac'), '');
      if v_name is not null then
        v_name_key := lower(v_name) || '|' || v_category;
      end if;

      if v_code is not null and length(v_code) > 40 then
        v_status := 'error';
        v_detail := 'code is too long';
      elsif v_code is null and v_name is null then
        v_status := 'error';
        v_detail := 'name is required';
      elsif v_category not in ('consultation', 'procedure', 'lab', 'imaging', 'consumable', 'room', 'package', 'other') then
        v_status := 'error';
        v_detail := 'category is not recognised';
      elsif (v_row ->> 'unitPricePaise') is null or (v_row ->> 'unitPricePaise') !~ '^[0-9]+$' then
        v_status := 'error';
        v_detail := 'unitPricePaise must be zero or more paise';
      elsif nullif(v_row ->> 'effectiveFrom', '') is null
            or (v_row ->> 'effectiveFrom') !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error';
        v_detail := 'effectiveFrom is required';
      elsif nullif(v_row ->> 'effectiveTo', '') is not null
            and (v_row ->> 'effectiveTo') !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error';
        v_detail := 'effectiveTo is not a date';
      elsif nullif(v_row ->> 'branchId', '') is not null
            and (v_row ->> 'branchId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_status := 'error';
        v_detail := 'branchId is not a uuid';
      elsif nullif(v_row ->> 'practitionerId', '') is not null
            and (v_row ->> 'practitionerId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_status := 'error';
        v_detail := 'practitionerId is not a uuid';
      else
        v_paise := (v_row ->> 'unitPricePaise')::bigint;
        v_from := (v_row ->> 'effectiveFrom')::date;
        v_to := nullif(v_row ->> 'effectiveTo', '')::date;
        v_branch := nullif(v_row ->> 'branchId', '')::uuid;
        v_prac := nullif(v_row ->> 'practitionerId', '')::uuid;
        if v_to is not null and v_to <= v_from then
          v_status := 'error';
          v_detail := 'effectiveTo must be after effectiveFrom';
        end if;
      end if;

      if v_status = 'ready' and v_branch is not null then
        if not identity.branch_exists_v1(p_tenant_id, v_branch) then
          v_status := 'error';
          v_detail := 'branch not found';
        elsif not billing.bypass_acl()
              and v_branch not in (select identity.current_branch_ids(p_tenant_id)) then
          v_status := 'error';
          v_detail := 'branch out of scope';
        end if;
      end if;

      if v_status = 'ready' and v_code is not null then
        select id, is_active into v_item, v_active
        from billing.service_item
        where tenant_id = p_tenant_id and code = v_code and not is_deleted;
        if v_item is null then
          v_item_action := 'create';
          if v_name is null or length(v_name) > 160 then
            v_status := 'error';
            v_detail := 'name is required for a new service';
          end if;
        elsif not v_active then
          v_status := 'error';
          v_detail := 'service is inactive';
          v_item_action := 'existing';
        else
          v_item_action := 'existing';
        end if;
      elsif v_status = 'ready' then
        select id, is_active, code into v_item, v_active, v_code
        from billing.service_item
        where tenant_id = p_tenant_id
          and not is_deleted
          and lower(name) = lower(v_name)
          and category = v_category
        order by created_on
        limit 1;
        if v_item is not null then
          v_item_action := 'existing';
          if not v_active then
            v_status := 'error';
            v_detail := 'service is inactive';
          end if;
        else
          select item_id, code into v_item, v_code
          from pg_temp.price_import_new
          where name_key = v_name_key;
          if v_item is not null then
            v_item_action := 'existing';
          else
            v_item_action := 'create';
            v_code := null;
          end if;
        end if;
      end if;

      if v_status = 'ready' and v_item is null then
        if v_sac is not null then
          select id into v_tax from billing.tax_code
          where tenant_id = p_tenant_id
            and not is_deleted
            and sac_hsn_code = v_sac
            and effective_from <= v_from
            and (effective_to is null or effective_to > v_from)
          order by effective_from desc
          limit 1;
          if v_tax is null then
            v_status := 'error';
            v_detail := 'no tax code for this SAC on the effective date';
          end if;
        else
          select tax_code_id into v_tax from billing.category_tax_default
          where tenant_id = p_tenant_id and category = v_category and not is_deleted;
          if v_tax is null then
            v_status := 'error';
            v_detail := 'no tax code for this category';
          end if;
        end if;
      end if;

      if v_status = 'ready' and v_item is not null then
        select id into v_list from billing.price_list
        where tenant_id = p_tenant_id
          and branch_id is not distinct from v_branch
          and name = 'Standard'
          and not is_deleted;
        if v_list is not null and billing.price_overlaps(v_list, v_item, v_prac, v_from, v_to) then
          v_status := 'price_overlap';
          v_detail := 'That price overlaps an existing effective period.';
        end if;
      end if;

      v_plan_key := coalesce(v_code, v_name_key);
      if v_status = 'ready' and v_plan_key is not null and exists (
        select 1 from pg_temp.price_import_plan plan
        where plan.branch_key = coalesce(v_branch, v_nil)
          and plan.item_key = v_plan_key
          and plan.practitioner_key = coalesce(v_prac, v_nil)
          and plan.active_range && daterange(v_from, v_to, '[)')
      ) then
        v_status := 'price_overlap';
        v_detail := 'That price overlaps another row in this file.';
      end if;

      if v_status = 'ready' and not v_dry then
        if v_item is null then
          v_code := billing.allocate_service_code(p_tenant_id, v_category, v_code);
          insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
          values (p_tenant_id, v_code, v_name, v_category, v_tax)
          returning id into v_item;
          if v_name_key is not null then
            insert into pg_temp.price_import_new (name_key, item_id, code)
            values (v_name_key, v_item, v_code)
            on conflict (name_key) do nothing;
          end if;
        end if;
        v_list := billing.ensure_standard_list(p_tenant_id, v_branch);
        insert into billing.price_list_item (
          tenant_id, price_list_id, service_item_id, practitioner_id, unit_price_paise, effective_from, effective_to)
        values (p_tenant_id, v_list, v_item, v_prac, v_paise, v_from, v_to);
      end if;
    exception
      when exclusion_violation then
        v_status := 'price_overlap';
        v_detail := 'That price overlaps an existing effective period.';
      when unique_violation then
        v_status := 'error';
        v_detail := 'that code is already in the price list';
      when invalid_datetime_format or datetime_field_overflow then
        v_status := 'error';
        v_detail := 'a date is not valid';
      when sqlstate '22023' then
        v_status := 'error';
        v_detail := sqlerrm;
    end;

    if v_status = 'ready' then
      v_plan_key := coalesce(v_code, v_name_key);
      if v_plan_key is not null then
        insert into pg_temp.price_import_plan (branch_key, item_key, practitioner_key, active_range)
        values (coalesce(v_branch, v_nil), v_plan_key, coalesce(v_prac, v_nil), daterange(v_from, v_to, '[)'));
      end if;
    end if;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'clientIndex', v_client,
      'code', v_code,
      'name', v_name,
      'status', v_status,
      'detail', v_detail,
      'item', v_item_action,
      'unitPricePaise', v_paise));
  end loop;

  return jsonb_build_object('dryRun', v_dry, 'rows', v_results);
end;
$$;

comment on function billing.import_prices(uuid, jsonb) is
  'CSV rows in paise. Code and SAC may be omitted. dryRun defaults to true and does not take a code number.';

revoke all on function billing.ensure_category_defaults(uuid) from public, anon, authenticated;
revoke all on function billing.allocate_service_code(uuid, text, text) from public, anon, authenticated;
revoke all on function billing.list_category_defaults(uuid) from public, anon, authenticated;
grant execute on function billing.ensure_category_defaults(uuid) to hms_svc_billing;
grant execute on function billing.allocate_service_code(uuid, text, text) to hms_svc_billing;
grant execute on function billing.list_category_defaults(uuid) to hms_svc_billing;
