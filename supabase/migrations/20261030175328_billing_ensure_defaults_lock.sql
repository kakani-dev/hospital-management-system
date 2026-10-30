-- #243: billing.ensure_defaults is called by every account open. Two first opens for a tenant at the
-- same time both saw no default CONSULT price and both inserted one; the second hit
-- price_list_item_no_overlap and the desk got 409 "That price overlaps an existing effective period".
-- Serialise the check-then-insert per tenant with a transaction-scoped advisory lock (released at
-- commit/rollback; other tenants are not blocked). Body otherwise unchanged.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

CREATE OR REPLACE FUNCTION billing.ensure_defaults(p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tax uuid;
  v_item uuid;
  v_list uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('billing.ensure_defaults:' || p_tenant_id::text, 0));
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
  insert into billing.approval_settings (tenant_id) values (p_tenant_id)
  on conflict (tenant_id) do nothing;
end;
$function$;
