-- cross-schema: approved (same calls as billing.allocate_service_code and billing.import_prices
-- already made: identity.has_tenant_permission, identity.branch_exists_v1, identity.current_branch_ids.
-- No new table reads outside billing. No rows are rewritten.)
-- Service codes are assigned by the server.
--
-- Additive: replaces three functions. No new table, no column, no rewrite of billing.service_item
-- or billing.service_code_seq. Codes already stored (CONSULT, and any code a hospital saved) stay.
--
-- allocate_service_code keeps its (uuid, text, text) signature so the existing grant stays.
-- A non-blank third argument is rejected. The number still comes from billing.service_code_seq.
-- upsert_service_item rejects a client code on create and on update. The stored code is not in the SET list.
-- import_prices ignores a code column. A row matches the oldest live service with the same name
-- (case-insensitive) and category, or creates one and allocates a code. SAC is unchanged.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create or replace function billing.allocate_service_code(p_tenant_id uuid, p_category text, p_custom text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prefix text;
  v_n bigint;
  v_code text;
begin
  -- Direct check: assert_permission treats the table owner as a bypass, and this function
  -- is security definer so it runs as that owner. The JWT still identifies the caller.
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, 'billing.pricelist_manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  -- The third argument stays so the signature (and its grant) does not change. It is never stored.
  if nullif(btrim(coalesce(p_custom, '')), '') is not null then
    raise exception 'Service codes are assigned by the server and cannot be supplied.' using errcode = '22023';
  end if;
  select code_prefix into v_prefix from billing.service_category where category = p_category;
  if v_prefix is null then
    raise exception 'category is not recognised' using errcode = '22023';
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
  'Next PREFIX-0001 code for the category. A supplied code is rejected. Existing codes are not rewritten.';


-- Code is immutable. Omit taxCodeId to use the category default.
-- A deactivate that sends only id and isActive does not change the tax.
-- A client-supplied code is rejected on create and on update.
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

  if v_code is not null then
    raise exception 'Service codes are assigned by the server and cannot be supplied.' using errcode = '22023';
  end if;

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
    v_code := billing.allocate_service_code(p_tenant_id, v_category, null);
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

comment on function billing.upsert_service_item(uuid, jsonb) is
  'Creates a service with the next allocated code, or updates name, category, tax and active flag. A client code is rejected. The stored code is immutable.';


-- A code column is ignored. Name and category match an existing service, or a new one is created.
-- A blank SAC uses the category default. An explicit SAC still picks a tax code by SAC.
-- A dry run does not take a code number.
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
      -- code is ignored. A row matches an existing service by name and category, or creates one.
      v_name := nullif(btrim(v_row ->> 'name'), '');
      v_category := coalesce(nullif(btrim(v_row ->> 'category'), ''), 'other');
      v_sac := nullif(btrim(v_row ->> 'sac'), '');
      if v_name is not null then
        v_name_key := lower(v_name) || '|' || v_category;
      end if;

      if v_name is null then
        v_status := 'error';
        v_detail := 'name is required';
      elsif length(v_name) > 160 then
        v_status := 'error';
        v_detail := 'name is too long';
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

      if v_status = 'ready' then
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
          v_code := billing.allocate_service_code(p_tenant_id, v_category, null);
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
  'CSV rows in paise. A code column is ignored. Rows match an existing service by name and category, or a new one is created with an allocated code. SAC may be omitted. dryRun defaults to true and does not take a code number.';
