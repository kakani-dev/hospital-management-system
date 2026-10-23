-- cross-schema: approved (billing calls identity.has_tenant_permission, identity.branch_exists_v1,
-- identity.current_branch_ids. No table reads outside billing.)
-- Price-list admin: catalog reads, branch copy, and a dry-run CSV import.
-- Money stays bigint paise. Service items are shared; a copy adds price rows only.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create or replace function billing.assert_catalog_read(p_tenant_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if billing.bypass_acl() then
    return;
  end if;
  if identity.has_tenant_permission(p_tenant_id, 'billing.view')
     or identity.has_tenant_permission(p_tenant_id, 'billing.pricelist_manage') then
    return;
  end if;
  raise exception 'permission denied' using errcode = '42501';
end;
$$;

create or replace function billing.ensure_standard_list(p_tenant_id uuid, p_branch_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_deleted boolean;
begin
  if p_branch_id is not null then
    perform billing.assert_branch(p_tenant_id, p_branch_id);
  end if;
  select id, is_deleted into v_id, v_deleted
  from billing.price_list
  where tenant_id = p_tenant_id
    and branch_id is not distinct from p_branch_id
    and name = 'Standard';
  if v_id is not null and not v_deleted then
    return v_id;
  end if;
  if v_deleted then
    raise exception 'the Standard price list was deleted' using errcode = '22023';
  end if;
  insert into billing.price_list (tenant_id, branch_id, name)
  values (p_tenant_id, p_branch_id, 'Standard')
  returning id into v_id;
  return v_id;
end;
$$;

-- True when a non-deleted row on this list already covers [from, to) for the item and practitioner.
create or replace function billing.price_overlaps(
  p_list uuid, p_item uuid, p_practitioner uuid, p_from date, p_to date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from billing.price_list_item pli
    where pli.price_list_id = p_list
      and pli.service_item_id = p_item
      and pli.practitioner_key = coalesce(p_practitioner, '00000000-0000-0000-0000-000000000000'::uuid)
      and not pli.is_deleted
      and pli.active_range && daterange(p_from, p_to, '[)')
  );
$$;

create or replace function billing.list_service_items(
  p_tenant_id uuid, p_query text, p_include_inactive boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
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
        and pli.effective_from <= current_date
        and (pli.effective_to is null or pli.effective_to > current_date)
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
$$;

create or replace function billing.list_tax_codes(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', tc.id,
      'code', tc.code,
      'sacHsnCode', tc.sac_hsn_code,
      'isExempt', tc.is_exempt,
      'rateBp', tc.rate_bp,
      'effectiveFrom', tc.effective_from,
      'effectiveTo', tc.effective_to
    ) order by tc.code, tc.effective_from)
    from billing.tax_code tc
    where tc.tenant_id = p_tenant_id and not tc.is_deleted
  ), '[]'::jsonb);
end;
$$;

create or replace function billing.list_price_lists(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pl.id,
      'name', pl.name,
      'branchId', pl.branch_id,
      'isActive', pl.is_active,
      'isPublicDisplay', pl.is_public_display,
      'schemeCode', pl.scheme_code
    ) order by pl.branch_id nulls first, pl.name)
    from billing.price_list pl
    where pl.tenant_id = p_tenant_id and not pl.is_deleted
  ), '[]'::jsonb);
end;
$$;

create or replace function billing.list_prices(p_tenant_id uuid, p_service_item_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pli.id,
      'priceListId', pli.price_list_id,
      'priceListName', pl.name,
      'branchId', pl.branch_id,
      'practitionerId', pli.practitioner_id,
      'unitPricePaise', pli.unit_price_paise,
      'effectiveFrom', pli.effective_from,
      'effectiveTo', pli.effective_to
    ) order by pli.effective_from desc, pl.branch_id nulls first)
    from billing.price_list_item pli
    join billing.price_list pl on pl.id = pli.price_list_id and not pl.is_deleted
    where pli.tenant_id = p_tenant_id
      and not pli.is_deleted
      and (p_service_item_id is null or pli.service_item_id = p_service_item_id)
  ), '[]'::jsonb);
end;
$$;

-- Code is immutable after create. Category and tax can change; bills snapshot price and tax rate only.
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
    if v_code is null or length(v_code) > 40 then
      raise exception 'code is required' using errcode = '22023';
    end if;
    if v_name is null or length(v_name) > 160 then
      raise exception 'name is required' using errcode = '22023';
    end if;
    if v_tax is null then
      select id into v_tax from billing.tax_code
      where tenant_id = p_tenant_id and code = 'EXEMPT' and not is_deleted
      order by effective_from desc
      limit 1;
    end if;
    if v_tax is null or not exists (
      select 1 from billing.tax_code
      where id = v_tax and tenant_id = p_tenant_id and not is_deleted
    ) then
      raise exception 'tax code not found' using errcode = 'P0002';
    end if;
    insert into billing.service_item (tenant_id, code, name, category, tax_code_id, is_stock_tracked)
    values (
      p_tenant_id, v_code, v_name, coalesce(v_category, 'other'), v_tax,
      coalesce((p_body ->> 'isStockTracked')::boolean, false))
    returning id into v_id;
  else
    if v_tax is not null and not exists (
      select 1 from billing.tax_code
      where id = v_tax and tenant_id = p_tenant_id and not is_deleted
    ) then
      raise exception 'tax code not found' using errcode = 'P0002';
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
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- priceListId or, when omitted, the Standard list for branchId (null branch = the hospital list).
create or replace function billing.add_price(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_list uuid := nullif(p_body ->> 'priceListId', '')::uuid;
  v_branch uuid := nullif(p_body ->> 'branchId', '')::uuid;
  v_item uuid := nullif(p_body ->> 'serviceItemId', '')::uuid;
  v_prac uuid := nullif(p_body ->> 'practitionerId', '')::uuid;
  v_paise bigint := (p_body ->> 'unitPricePaise')::bigint;
  v_from date := nullif(p_body ->> 'effectiveFrom', '')::date;
  v_to date := nullif(p_body ->> 'effectiveTo', '')::date;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  if v_item is null or v_from is null or v_paise is null or v_paise < 0 then
    raise exception 'service item, effectiveFrom and unitPricePaise are required' using errcode = '22023';
  end if;
  if v_to is not null and v_to <= v_from then
    raise exception 'effectiveTo must be after effectiveFrom' using errcode = '22023';
  end if;
  if not exists (
    select 1 from billing.service_item
    where id = v_item and tenant_id = p_tenant_id and not is_deleted
  ) then
    raise exception 'service item not found' using errcode = 'P0002';
  end if;
  if v_list is null then
    v_list := billing.ensure_standard_list(p_tenant_id, v_branch);
  elsif not exists (
    select 1 from billing.price_list
    where id = v_list and tenant_id = p_tenant_id and not is_deleted
  ) then
    raise exception 'price list not found' using errcode = 'P0002';
  end if;
  insert into billing.price_list_item (
    tenant_id, price_list_id, service_item_id, practitioner_id, unit_price_paise, effective_from, effective_to)
  values (p_tenant_id, v_list, v_item, v_prac, v_paise, v_from, v_to)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- Copies rates in force on effectiveFrom onto the branch list of the same name.
-- Service items are not duplicated. Overlapping rows are skipped and listed.
create or replace function billing.copy_price_list(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_source uuid := nullif(p_body ->> 'sourcePriceListId', '')::uuid;
  v_branch uuid := nullif(p_body ->> 'branchId', '')::uuid;
  v_from date := nullif(p_body ->> 'effectiveFrom', '')::date;
  v_name text;
  v_dry boolean := coalesce((p_body ->> 'dryRun')::boolean, false);
  v_target uuid;
  v_copied integer := 0;
  v_conflicts jsonb := '[]'::jsonb;
  v_to date;
  r record;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.assert_branch(p_tenant_id, v_branch);
  if v_source is null or v_from is null then
    raise exception 'sourcePriceListId and effectiveFrom are required' using errcode = '22023';
  end if;
  select name into v_name from billing.price_list
  where id = v_source and tenant_id = p_tenant_id and not is_deleted;
  if v_name is null then
    raise exception 'price list not found' using errcode = 'P0002';
  end if;
  v_name := coalesce(nullif(btrim(p_body ->> 'name'), ''), v_name);
  if length(v_name) > 120 then
    raise exception 'name is too long' using errcode = '22023';
  end if;
  select id into v_target from billing.price_list
  where tenant_id = p_tenant_id and branch_id = v_branch and name = v_name and not is_deleted;
  if v_target is not distinct from v_source then
    raise exception 'choose a different branch' using errcode = '22023';
  end if;

  for r in
    select pli.service_item_id, pli.practitioner_id, pli.unit_price_paise, pli.effective_to, si.code, si.name
    from billing.price_list_item pli
    join billing.service_item si on si.id = pli.service_item_id and si.is_active and not si.is_deleted
    where pli.price_list_id = v_source
      and pli.tenant_id = p_tenant_id
      and not pli.is_deleted
      and pli.effective_from <= v_from
      and (pli.effective_to is null or pli.effective_to > v_from)
  loop
    v_to := case when r.effective_to is not null and r.effective_to > v_from then r.effective_to else null end;
    if v_target is not null and billing.price_overlaps(v_target, r.service_item_id, r.practitioner_id, v_from, v_to) then
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'name', r.name, 'practitionerId', r.practitioner_id, 'reason', 'price_overlap'));
    else
      v_copied := v_copied + 1;
      if not v_dry then
        if v_target is null then
          insert into billing.price_list (tenant_id, branch_id, name)
          values (p_tenant_id, v_branch, v_name)
          returning id into v_target;
        end if;
        insert into billing.price_list_item (
          tenant_id, price_list_id, service_item_id, practitioner_id, unit_price_paise, effective_from, effective_to)
        values (
          p_tenant_id, v_target, r.service_item_id, r.practitioner_id, r.unit_price_paise, v_from, v_to);
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'priceListId', v_target, 'copied', v_copied, 'conflicts', v_conflicts, 'dryRun', v_dry);
end;
$$;

-- dryRun defaults to true: nothing is written until the caller sends dryRun false.
-- Each row is ready, error, or price_overlap. Overlaps in the file and in the database are both reported.
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
    code text not null,
    practitioner_key uuid not null,
    active_range daterange not null
  ) on commit drop;
  delete from pg_temp.price_import_plan;

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
      v_sac := coalesce(nullif(btrim(v_row ->> 'sac'), ''), '9993');

      if v_code is null or length(v_code) > 40 then
        v_status := 'error';
        v_detail := 'code is required';
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
        select id, is_active into v_item, v_active
        from billing.service_item
        where tenant_id = p_tenant_id and code = v_code and not is_deleted;
        if v_item is null then
          v_item_action := 'create';
          if v_name is null or length(v_name) > 160 then
            v_status := 'error';
            v_detail := 'name is required for a new service';
          else
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
          end if;
        elsif not v_active then
          v_status := 'error';
          v_detail := 'service is inactive';
          v_item_action := 'existing';
        else
          v_item_action := 'existing';
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

      if v_status = 'ready' and exists (
        select 1 from pg_temp.price_import_plan plan
        where plan.branch_key = coalesce(v_branch, v_nil)
          and plan.code = v_code
          and plan.practitioner_key = coalesce(v_prac, v_nil)
          and plan.active_range && daterange(v_from, v_to, '[)')
      ) then
        v_status := 'price_overlap';
        v_detail := 'That price overlaps another row in this file.';
      end if;

      if v_status = 'ready' and not v_dry then
        if v_item is null then
          insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
          values (p_tenant_id, v_code, v_name, v_category, v_tax)
          returning id into v_item;
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
      when invalid_datetime_format or datetime_field_overflow then
        v_status := 'error';
        v_detail := 'a date is not valid';
    end;

    if v_status = 'ready' then
      insert into pg_temp.price_import_plan (branch_key, code, practitioner_key, active_range)
      values (coalesce(v_branch, v_nil), v_code, coalesce(v_prac, v_nil), daterange(v_from, v_to, '[)'));
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

comment on function billing.list_service_items(uuid, text, boolean) is
  'Active catalog for cashiers (billing.view) and admins. hospitalPricePaise is the open hospital rate today.';
comment on function billing.list_tax_codes(uuid) is
  'SAC and GST rates a price-list admin can attach to a service.';
comment on function billing.list_price_lists(uuid) is
  'Hospital lists (branch_id null) and branch lists.';
comment on function billing.list_prices(uuid, uuid) is
  'Append-only price rows. Pass a service item to limit the list.';
comment on function billing.copy_price_list(uuid, jsonb) is
  'Copies in-force rates onto a branch list. dryRun true writes nothing. Overlaps are skipped.';
comment on function billing.import_prices(uuid, jsonb) is
  'CSV rows already converted to paise. dryRun defaults to true and reports price_overlap before any write.';

revoke all on all functions in schema billing from public, anon, authenticated;
grant execute on all functions in schema billing to hms_svc_billing;
grant execute on function billing.public_link(text) to anon;
grant execute on function billing.apply_webhook(text, jsonb) to anon;
