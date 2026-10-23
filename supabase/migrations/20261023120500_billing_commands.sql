-- cross-schema: approved (billing calls identity.has_tenant_permission, identity.current_branch_ids,
-- identity.branch_exists_v1, identity.branch_local_date_v1, identity.caller_roles_v1,
-- patient.patient_exists_v1, appointment.appointment_billing_ref_v1.
-- No table reads outside billing. messaging.enqueue stays inside the definer outbox trigger.)
-- Commands, computed totals and the public receipt / webhook entry points.
-- Amounts are bigint paise. Totals, due and advance balances are computed, never stored.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

-- --------------------------------------------------------------------- money ----
create or replace function billing.line_net(p_quantity numeric, p_unit_price_paise bigint)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select round(p_quantity * p_unit_price_paise, 0)::bigint
$$;

create or replace function billing.line_tax(p_quantity numeric, p_unit_price_paise bigint, p_tax_rate_bp integer)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select round(billing.line_net(p_quantity, p_unit_price_paise) * p_tax_rate_bp / 10000.0, 0)::bigint
$$;

create or replace function billing.bill_gross(p_bill_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(
    billing.line_net(l.quantity, l.unit_price_paise) + billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp)
  ), 0)::bigint
  from billing.bill_line l
  where l.bill_id = p_bill_id and not l.is_deleted
$$;

create or replace function billing.discount_total(p_bill_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select least(
    coalesce(sum(
      case d.kind
        when 'flat_paise' then d.value
        else round(
          (case
             when d.bill_line_id is null then billing.bill_gross(d.bill_id)
             else (
               select billing.line_net(l.quantity, l.unit_price_paise)
                    + billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp)
               from billing.bill_line l
               where l.id = d.bill_line_id and not l.is_deleted)
           end) * d.value / 10000.0, 0)::bigint
      end
    ), 0),
    greatest(billing.bill_gross(p_bill_id), 0)
  )::bigint
  from billing.discount d
  join billing.approval_request a on a.id = d.approval_id
  where d.bill_id = p_bill_id
    and not d.is_deleted
    and not a.is_deleted
    and a.status = 'approved'
$$;

create or replace view billing.bill_totals_v1
with (security_invoker = true) as
select b.id as bill_id,
       b.tenant_id,
       b.account_id,
       coalesce(g.net_paise, 0)::bigint as net_paise,
       coalesce(g.tax_paise, 0)::bigint as tax_paise,
       billing.discount_total(b.id) as discount_paise,
       (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id))::bigint as exact_paise,
       (
         round((coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id)) / 100.0, 0) * 100
         - (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id))
       )::bigint as round_off_paise,
       (round((coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id)) / 100.0, 0) * 100)::bigint as total_paise
from billing.bill b
left join lateral (
  select sum(billing.line_net(l.quantity, l.unit_price_paise))::bigint as net_paise,
         sum(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp))::bigint as tax_paise
  from billing.bill_line l
  where l.bill_id = b.id and not l.is_deleted
) g on true
where not b.is_deleted;

comment on view billing.bill_totals_v1 is
  'Computed bill total. Round-off is to the nearest rupee (half away from zero) and is not a stored line.';

create or replace view billing.bill_balance_v1
with (security_invoker = true) as
select t.bill_id,
       t.tenant_id,
       t.account_id,
       t.total_paise,
       coalesce(c.credited_paise, 0)::bigint as credited_paise,
       coalesce(al.allocated_paise, 0)::bigint as allocated_paise,
       (t.total_paise - coalesce(c.credited_paise, 0) - coalesce(al.allocated_paise, 0))::bigint as due_paise
from billing.bill_totals_v1 t
left join lateral (
  select sum(-ct.total_paise)::bigint as credited_paise
  from billing.bill cn
  join billing.bill_totals_v1 ct on ct.bill_id = cn.id
  where cn.reverses_bill_id = t.bill_id
    and cn.bill_kind = 'credit_note'
    and cn.status = 'finalized'
    and not cn.is_deleted
) c on true
left join lateral (
  select sum(a.amount_paise)::bigint as allocated_paise
  from billing.allocation a
  where a.bill_id = t.bill_id and not a.is_deleted
) al on true;

comment on view billing.bill_balance_v1 is
  'Due = total − finalized credit notes that reverse this bill − allocations. Never stored.';

create or replace view billing.patient_advance_v1
with (security_invoker = true) as
select a.tenant_id,
       a.patient_id,
       coalesce(sum(
         case p.kind when 'refund' then -p.amount_paise else p.amount_paise end
         - coalesce((
             select sum(al.amount_paise) from billing.allocation al
             where al.payment_id = p.id and not al.is_deleted
           ), 0)
       ), 0)::bigint as advance_paise
from billing.billing_account a
join billing.payment p on p.account_id = a.id and not p.is_deleted
where not a.is_deleted
group by a.tenant_id, a.patient_id;

comment on view billing.patient_advance_v1 is
  'Unallocated receipts and advances, minus refunds, for one patient across the whole tenant.';

-- Price rows are append-only. A later effective row replaces history.
create or replace function billing.reject_price_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.unit_price_paise is distinct from old.unit_price_paise
     or new.effective_from is distinct from old.effective_from
     or new.effective_to is distinct from old.effective_to
     or new.service_item_id is distinct from old.service_item_id
     or new.practitioner_id is distinct from old.practitioner_id
     or new.price_list_id is distinct from old.price_list_id then
    raise exception 'price rows are append-only' using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger price_list_item_append_only
  before update on billing.price_list_item
  for each row execute function billing.reject_price_edit();

create index if not exists payment_received_idx
  on billing.payment (tenant_id, received_at)
  where not is_deleted;
create index if not exists bill_status_idx
  on billing.bill (tenant_id, status)
  where not is_deleted;
create index if not exists payment_link_bill_idx
  on billing.payment_link (bill_id)
  where not is_deleted;

-- --------------------------------------------------------------------- guards ----
create or replace function billing.bypass_acl()
returns boolean
language sql
stable
set search_path = ''
as $$
  select pg_catalog.pg_get_userbyid(c.relowner) = current_user
  from pg_catalog.pg_class c
  where c.oid = 'billing.bill'::regclass
$$;

create or replace function billing.assert_permission(p_tenant_id uuid, p_permission text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if billing.bypass_acl() then
    return;
  end if;
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, p_permission) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
end;
$$;

create or replace function billing.assert_branch(p_tenant_id uuid, p_branch_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_branch_id is null or not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if not billing.bypass_acl()
     and p_branch_id not in (select identity.current_branch_ids(p_tenant_id)) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
end;
$$;

create or replace function billing.assert_patient(p_tenant_id uuid, p_patient_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_patient_id is null or not patient.patient_exists_v1(p_tenant_id, p_patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function billing.caller_policy_roles(p_tenant_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select case
    when 'tenant_admin' = any (identity.caller_roles_v1(p_tenant_id))
      then (
        select coalesce(array_agg(distinct r), array[]::text[])
        from unnest(identity.caller_roles_v1(p_tenant_id) || array['supervisor', 'manager']::text[]) r)
    else identity.caller_roles_v1(p_tenant_id)
  end
$$;

create or replace function billing.caller_is_manager(p_tenant_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select 'manager' = any (billing.caller_policy_roles(p_tenant_id))
$$;

-- Auto-approve when the amount is within the rupee cap OR the percent is within the percent cap.
-- Null amount and null percent together mean unlimited.
create or replace function billing.within_limit(
  p_tenant_id uuid, p_action text, p_amount_paise bigint, p_percent_bp integer)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from billing.approval_policy p
    where p.tenant_id = p_tenant_id
      and p.action = p_action
      and not p.is_deleted
      and p.role = any (billing.caller_policy_roles(p_tenant_id))
      and (
        (p.max_amount_paise is null and p.max_percent_bp is null)
        or (p.max_amount_paise is not null and p_amount_paise <= p.max_amount_paise)
        or (p.max_percent_bp is not null and p_percent_bp is not null and p_percent_bp <= p.max_percent_bp)
      )
  )
$$;

-- The published zone function treats an anon session as a client and 404s every branch.
-- The webhook runs as anon, so that path reads the zone here (owner only) and nowhere else.
create or replace function billing.branch_day(p_branch_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_zone text;
begin
  if pg_catalog.current_setting('role', true) is distinct from 'anon' then
    return identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
  end if;
  select coalesce(b.timezone_override, t.time_zone) into v_zone
  from identity.branches b
  join identity.tenants t on t.id = b.tenant_id
  where b.id = p_branch_id and not b.is_deleted and not t.is_deleted;
  if v_zone is null then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  return (pg_catalog.now() at time zone v_zone)::date;
end;
$$;

create or replace function billing.fiscal_label(p_on date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when extract(month from p_on) >= 4
      then to_char(p_on, 'YY') || to_char((p_on + interval '1 year')::date, 'YY')
    else to_char((p_on - interval '1 year')::date, 'YY') || to_char(p_on, 'YY')
  end
$$;

create or replace function billing.format_doc_no(p_prefix text, p_letter text, p_fy text, p_serial bigint)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body text := p_prefix || p_letter || p_fy;
  v_width integer := 16 - length(v_body);
begin
  if v_width < 1 or p_serial < 1 or p_serial > (power(10, v_width) - 1)::bigint then
    raise exception 'document number does not fit in 16 characters' using errcode = '22023';
  end if;
  return v_body || lpad(p_serial::text, v_width, '0');
end;
$$;

create or replace function billing.assign_number(p_tenant_id uuid, p_branch_id uuid, p_doc_type text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_prefix text;
  v_fy text;
  v_serial bigint;
  v_letter text;
  v_day date;
begin
  v_day := billing.branch_day(p_branch_id);
  v_fy := billing.fiscal_label(v_day);
  select bp.doc_prefix into v_prefix
  from billing.branch_profile bp
  where bp.tenant_id = p_tenant_id and bp.branch_id = p_branch_id and not bp.is_deleted;
  if v_prefix is null then
    v_prefix := 'OP';
  end if;
  v_letter := case p_doc_type
    when 'bill' then 'B'
    when 'credit_note' then 'C'
    else 'R'
  end;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_tenant_id::text || p_branch_id::text || p_doc_type || v_fy, 0));
  insert into billing.bill_number_series (tenant_id, branch_id, doc_type, fiscal_year, prefix, next_value)
  select p_tenant_id, p_branch_id, p_doc_type, v_fy, v_prefix, 1
  where not exists (
    select 1 from billing.bill_number_series s
    where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id
      and s.doc_type = p_doc_type and s.fiscal_year = v_fy and not s.is_deleted);
  update billing.bill_number_series s
  set next_value = s.next_value + 1
  where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id
    and s.doc_type = p_doc_type and s.fiscal_year = v_fy and not s.is_deleted
  returning s.next_value - 1 into v_serial;
  return billing.format_doc_no(v_prefix, v_letter, v_fy, v_serial);
end;
$$;

-- s.269ST: cash that would take the patient to ₹2,00,000 or more on this branch-local day is refused.
create or replace function billing.assert_cash_ceiling(
  p_tenant_id uuid, p_patient_id uuid, p_branch_id uuid, p_cash_paise bigint)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_day date;
  v_already bigint;
begin
  if p_cash_paise is null or p_cash_paise <= 0 then
    return;
  end if;
  v_day := billing.branch_day(p_branch_id);
  select coalesce(sum(t.amount_paise), 0) into v_already
  from billing.payment_tender t
  join billing.payment p on p.id = t.payment_id and not p.is_deleted
  join billing.billing_account a on a.id = p.account_id and not a.is_deleted
  where t.tenant_id = p_tenant_id
    and t.mode = 'cash'
    and not t.is_deleted
    and p.kind in ('payment', 'advance')
    and a.patient_id = p_patient_id
    and identity.branch_local_date_v1(a.branch_id, p.received_at) = v_day;
  if v_already + p_cash_paise >= 20000000 then
    raise exception 'cash would reach the ₹2,00,000 daily limit for this patient' using errcode = '22023';
  end if;
end;
$$;

-- --------------------------------------------------------------------- catalog ----
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

create or replace function billing.resolve_price(
  p_tenant_id uuid, p_branch_id uuid, p_service_item_id uuid, p_practitioner_id uuid, p_on date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row record;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  select pli.id as price_list_item_id, pli.unit_price_paise, tc.rate_bp as tax_rate_bp, si.code, si.name
  into v_row
  from billing.price_list_item pli
  join billing.price_list pl on pl.id = pli.price_list_id and pl.is_active and not pl.is_deleted
  join billing.service_item si on si.id = pli.service_item_id and si.is_active and not si.is_deleted
  join billing.tax_code tc on tc.id = si.tax_code_id and not tc.is_deleted
  where pli.tenant_id = p_tenant_id
    and pli.service_item_id = p_service_item_id
    and not pli.is_deleted
    and pli.effective_from <= p_on
    and (pli.effective_to is null or pli.effective_to > p_on)
    and (pl.branch_id is null or pl.branch_id = p_branch_id)
    and (pli.practitioner_id is null or pli.practitioner_id = p_practitioner_id)
  order by
    case when pli.practitioner_id = p_practitioner_id and p_practitioner_id is not null then 0 else 1 end,
    case when pl.branch_id = p_branch_id then 0 when pl.branch_id is null then 1 else 2 end,
    pli.effective_from desc
  limit 1;
  if v_row.price_list_item_id is null then
    raise exception 'no price for this service on this date' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'priceListItemId', v_row.price_list_item_id,
    'unitPricePaise', v_row.unit_price_paise,
    'taxRateBp', v_row.tax_rate_bp,
    'code', v_row.code,
    'name', v_row.name);
end;
$$;

create or replace function billing.upsert_service_item(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_body ->> 'id', '')::uuid;
  v_code text := btrim(p_body ->> 'code');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.ensure_defaults(p_tenant_id);
  if v_code is null or length(v_code) < 1 then
    raise exception 'code is required' using errcode = '22023';
  end if;
  if v_id is null then
    insert into billing.service_item (tenant_id, code, name, category, tax_code_id, is_stock_tracked)
    values (
      p_tenant_id, v_code, btrim(p_body ->> 'name'), coalesce(p_body ->> 'category', 'other'),
      (p_body ->> 'taxCodeId')::uuid, coalesce((p_body ->> 'isStockTracked')::boolean, false))
    returning id into v_id;
  else
    update billing.service_item
    set name = coalesce(btrim(p_body ->> 'name'), name),
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

create or replace function billing.upsert_price_list(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_body ->> 'id', '')::uuid;
  v_branch uuid := nullif(p_body ->> 'branchId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  if v_branch is not null then
    perform billing.assert_branch(p_tenant_id, v_branch);
  end if;
  if v_id is null then
    insert into billing.price_list (tenant_id, branch_id, name, is_public_display, scheme_code)
    values (p_tenant_id, v_branch, btrim(p_body ->> 'name'),
            coalesce((p_body ->> 'isPublicDisplay')::boolean, false), nullif(p_body ->> 'schemeCode', ''))
    returning id into v_id;
  else
    update billing.price_list
    set name = coalesce(btrim(p_body ->> 'name'), name),
        is_active = coalesce((p_body ->> 'isActive')::boolean, is_active)
    where id = v_id and tenant_id = p_tenant_id and not is_deleted;
    if not found then
      raise exception 'price list not found' using errcode = 'P0002';
    end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function billing.add_price(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  insert into billing.price_list_item (
    tenant_id, price_list_id, service_item_id, practitioner_id, unit_price_paise, effective_from, effective_to)
  values (
    p_tenant_id,
    (p_body ->> 'priceListId')::uuid,
    (p_body ->> 'serviceItemId')::uuid,
    nullif(p_body ->> 'practitionerId', '')::uuid,
    (p_body ->> 'unitPricePaise')::bigint,
    (p_body ->> 'effectiveFrom')::date,
    nullif(p_body ->> 'effectiveTo', '')::date)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function billing.set_branch_prefix(p_tenant_id uuid, p_branch_id uuid, p_prefix text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  if p_prefix !~ '^[A-Z0-9]{1,4}$' then
    raise exception 'prefix must be 1 to 4 letters or digits' using errcode = '22023';
  end if;
  insert into billing.branch_profile (tenant_id, branch_id, doc_prefix)
  values (p_tenant_id, p_branch_id, p_prefix)
  on conflict (tenant_id, branch_id) do update set doc_prefix = excluded.doc_prefix;
  return jsonb_build_object('branchId', p_branch_id, 'docPrefix', p_prefix);
end;
$$;

-- --------------------------------------------------------------------- documents ----
create or replace function billing.bill_json(p_bill_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_account billing.billing_account%rowtype;
  v_totals billing.bill_totals_v1%rowtype;
  v_due bigint;
  v_lines jsonb;
  v_discounts jsonb;
begin
  select * into v_bill from billing.bill where id = p_bill_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  select * into v_totals from billing.bill_totals_v1 where bill_id = p_bill_id;
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', l.id, 'lineNo', l.line_no, 'serviceItemId', l.service_item_id,
    'code', si.code, 'name', si.name, 'quantity', l.quantity,
    'unitPricePaise', l.unit_price_paise, 'taxRateBp', l.tax_rate_bp,
    'netPaise', billing.line_net(l.quantity, l.unit_price_paise),
    'taxPaise', billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
    'practitionerId', l.practitioner_id
  ) order by l.line_no), '[]'::jsonb) into v_lines
  from billing.bill_line l
  join billing.service_item si on si.id = l.service_item_id
  where l.bill_id = p_bill_id and not l.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'billLineId', d.bill_line_id, 'kind', d.kind, 'value', d.value,
    'reasonCode', d.reason_code, 'approvalId', d.approval_id
  )), '[]'::jsonb) into v_discounts
  from billing.discount d
  join billing.approval_request a on a.id = d.approval_id and a.status = 'approved' and not a.is_deleted
  where d.bill_id = p_bill_id and not d.is_deleted;
  return jsonb_build_object(
    'id', v_bill.id, 'billNo', v_bill.bill_no, 'status', v_bill.status, 'billKind', v_bill.bill_kind,
    'payerType', v_bill.payer_type, 'accountId', v_bill.account_id, 'patientId', v_account.patient_id,
    'branchId', v_account.branch_id, 'reversesBillId', v_bill.reverses_bill_id,
    'lines', v_lines, 'discounts', v_discounts,
    'netPaise', v_totals.net_paise, 'taxPaise', v_totals.tax_paise,
    'discountPaise', v_totals.discount_paise, 'exactPaise', v_totals.exact_paise,
    'roundOffPaise', v_totals.round_off_paise, 'totalPaise', v_totals.total_paise,
    'duePaise', coalesce(v_due, v_totals.total_paise));
end;
$$;

create or replace function billing.bill_document(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_doc jsonb;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  v_doc := billing.bill_json(p_bill_id);
  if (v_doc ->> 'patientId') is null or (v_doc ->> 'id') is null
     or not exists (select 1 from billing.bill b where b.id = p_bill_id and b.tenant_id = p_tenant_id) then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  return v_doc;
end;
$$;

create or replace function billing.receipt_json(p_payment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pay billing.payment%rowtype;
  v_tenders jsonb;
  v_alloc jsonb;
begin
  select * into v_pay from billing.payment where id = p_payment_id and not is_deleted;
  if v_pay.id is null then
    raise exception 'receipt not found' using errcode = 'P0002';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'mode', t.mode, 'amountPaise', t.amount_paise, 'reference', t.reference
  )), '[]'::jsonb) into v_tenders
  from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'billId', a.bill_id, 'amountPaise', a.amount_paise
  )), '[]'::jsonb) into v_alloc
  from billing.allocation a where a.payment_id = p_payment_id and not a.is_deleted;
  return jsonb_build_object(
    'id', v_pay.id, 'receiptNo', v_pay.receipt_no, 'kind', v_pay.kind,
    'amountPaise', v_pay.amount_paise, 'idempotencyKey', v_pay.idempotency_key,
    'accountId', v_pay.account_id, 'refundOfPaymentId', v_pay.refund_of_payment_id,
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc);
end;
$$;

create or replace function billing.open_account(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_patient uuid := (p_body ->> 'patientId')::uuid;
  v_branch uuid := (p_body ->> 'branchId')::uuid;
  v_type text := coalesce(p_body ->> 'accountType', 'walk_in');
  v_account uuid;
  v_bill uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  perform billing.assert_branch(p_tenant_id, v_branch);
  perform billing.assert_patient(p_tenant_id, v_patient);
  perform billing.ensure_defaults(p_tenant_id);
  insert into billing.billing_account (tenant_id, patient_id, branch_id, account_type, source_ref_type, source_ref_id)
  values (p_tenant_id, v_patient, v_branch, v_type, 'none', null)
  returning id into v_account;
  insert into billing.bill (tenant_id, account_id, bill_kind, payer_type)
  values (p_tenant_id, v_account, 'final', coalesce(p_body ->> 'payerType', 'self'))
  returning id into v_bill;
  return billing.bill_json(v_bill) || jsonb_build_object('accountId', v_account);
end;
$$;

create or replace function billing.add_line(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_account billing.billing_account%rowtype;
  v_bill billing.bill%rowtype;
  v_item uuid;
  v_price jsonb;
  v_line int;
  v_qty numeric := coalesce((p_body ->> 'quantity')::numeric, 1);
  v_prac uuid := nullif(p_body ->> 'practitionerId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_bill.status <> 'draft' then
    raise exception 'only a draft bill accepts lines' using errcode = '55000';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  perform billing.assert_branch(p_tenant_id, v_account.branch_id);
  if nullif(p_body ->> 'serviceItemId', '') is not null then
    v_item := (p_body ->> 'serviceItemId')::uuid;
  else
    select id into v_item from billing.service_item
    where tenant_id = p_tenant_id and code = coalesce(p_body ->> 'code', 'CONSULT') and not is_deleted;
  end if;
  if v_item is null then
    raise exception 'service item not found' using errcode = 'P0002';
  end if;
  v_price := billing.resolve_price(
    p_tenant_id, v_account.branch_id, v_item, coalesce(v_prac, null),
    identity.branch_local_date_v1(v_account.branch_id, pg_catalog.now()));
  select coalesce(max(line_no), 0) + 1 into v_line from billing.bill_line where bill_id = p_bill_id;
  insert into billing.bill_line (
    tenant_id, bill_id, line_no, service_item_id, price_list_item_id, practitioner_id,
    quantity, unit_price_paise, tax_rate_bp)
  values (
    p_tenant_id, p_bill_id, v_line, v_item, (v_price ->> 'priceListItemId')::uuid, v_prac,
    v_qty, (v_price ->> 'unitPricePaise')::bigint, (v_price ->> 'taxRateBp')::integer);
  return billing.bill_json(p_bill_id);
end;
$$;

create or replace function billing.remove_line(p_tenant_id uuid, p_bill_id uuid, p_line_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_branch uuid;
begin
  if not identity.has_tenant_permission(p_tenant_id, 'billing.bill') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select b.status, a.branch_id into v_status, v_branch
  from billing.bill b
  join billing.billing_account a on a.id = b.account_id
  where b.id = p_bill_id and b.tenant_id = p_tenant_id and not b.is_deleted;
  if v_status is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_branch is null or v_branch not in (select identity.current_branch_ids(p_tenant_id)) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
  if v_status <> 'draft' then
    raise exception 'only a draft line can be removed' using errcode = '55000';
  end if;
  update billing.bill_line set is_deleted = true
  where id = p_line_id and bill_id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
  if not found then
    raise exception 'line not found' using errcode = 'P0002';
  end if;
  return billing.bill_json(p_bill_id);
end;
$$;

create or replace function billing.finalize_bill(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_branch uuid;
  v_doc text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select branch_id into v_branch from billing.billing_account where id = v_bill.account_id;
  perform billing.assert_branch(p_tenant_id, v_branch);
  if v_bill.status <> 'draft' then
    raise exception 'only a draft bill can be finalized' using errcode = '55000';
  end if;
  if not exists (select 1 from billing.bill_line l where l.bill_id = p_bill_id and not l.is_deleted) then
    raise exception 'a bill needs at least one line' using errcode = '22023';
  end if;
  v_doc := billing.assign_number(p_tenant_id, v_branch,
    case when v_bill.bill_kind = 'credit_note' then 'credit_note' else 'bill' end);
  update billing.bill
  set status = 'finalized', bill_no = v_doc, finalized_at = pg_catalog.now(), finalized_by = audit.session_actor_id()
  where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

create or replace function billing.cancel_draft(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select status into v_status from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_status is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'only a draft bill can be cancelled' using errcode = '55000';
  end if;
  update billing.bill set status = 'cancelled_draft' where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

create or replace function billing.create_credit_note(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.bill%rowtype;
  v_note uuid;
  v_line jsonb;
  v_src_line billing.bill_line%rowtype;
  v_qty numeric;
  v_n int := 0;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_src from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted and status = 'finalized' and bill_kind <> 'credit_note';
  if v_src.id is null then
    raise exception 'finalized bill not found' using errcode = 'P0002';
  end if;
  insert into billing.bill (tenant_id, account_id, bill_kind, reverses_bill_id, payer_type)
  values (p_tenant_id, v_src.account_id, 'credit_note', v_src.id, v_src.payer_type)
  returning id into v_note;
  for v_line in select * from jsonb_array_elements(coalesce(p_body -> 'lines', '[]'::jsonb))
  loop
    v_qty := (v_line ->> 'quantity')::numeric;
    select * into v_src_line from billing.bill_line
    where id = (v_line ->> 'lineId')::uuid and bill_id = p_bill_id and not is_deleted;
    if v_src_line.id is null or v_qty is null or v_qty <= 0 or v_qty > v_src_line.quantity then
      raise exception 'credit quantity exceeds the original line' using errcode = '22023';
    end if;
    v_n := v_n + 1;
    insert into billing.bill_line (
      tenant_id, bill_id, line_no, service_item_id, price_list_item_id, practitioner_id,
      quantity, unit_price_paise, tax_rate_bp, reverses_line_id)
    values (
      p_tenant_id, v_note, v_n, v_src_line.service_item_id, v_src_line.price_list_item_id,
      v_src_line.practitioner_id, -v_qty, v_src_line.unit_price_paise, v_src_line.tax_rate_bp, v_src_line.id);
  end loop;
  if v_n = 0 then
    raise exception 'a credit note needs a line' using errcode = '22023';
  end if;
  return billing.finalize_bill(p_tenant_id, v_note);
end;
$$;

-- --------------------------------------------------------------------- payments ----
create or replace function billing.collect_payment(p_tenant_id uuid, p_idem uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_existing uuid;
  v_account billing.billing_account%rowtype;
  v_kind text := coalesce(p_body ->> 'kind', 'payment');
  v_amount bigint := 0;
  v_cash bigint := 0;
  v_tender jsonb;
  v_alloc jsonb;
  v_alloc_sum bigint := 0;
  v_payment uuid;
  v_receipt text;
  v_session uuid := nullif(p_body ->> 'counterSessionId', '')::uuid;
begin
  if not billing.bypass_acl() then
    perform billing.assert_permission(p_tenant_id, 'billing.collect');
  end if;
  select id into v_existing from billing.payment
  where tenant_id = p_tenant_id and idempotency_key = p_idem and not is_deleted;
  if v_existing is not null then
    if (select amount_paise from billing.payment where id = v_existing)
       is distinct from coalesce((
         select sum((t ->> 'amountPaise')::bigint)
         from jsonb_array_elements(coalesce(p_body -> 'tenders', '[]'::jsonb)) t
       ), 0) then
      raise exception 'idempotency key reused with a different amount' using errcode = '23505';
    end if;
    return billing.receipt_json(v_existing);
  end if;
  select * into v_account from billing.billing_account
  where id = (p_body ->> 'accountId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  if v_account.id is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_kind not in ('payment', 'advance') then
    raise exception 'kind must be payment or advance' using errcode = '22023';
  end if;
  for v_tender in select * from jsonb_array_elements(coalesce(p_body -> 'tenders', '[]'::jsonb))
  loop
    v_amount := v_amount + (v_tender ->> 'amountPaise')::bigint;
    if v_tender ->> 'mode' = 'cash' then
      v_cash := v_cash + (v_tender ->> 'amountPaise')::bigint;
    end if;
  end loop;
  if v_amount <= 0 then
    raise exception 'a payment needs a tender' using errcode = '22023';
  end if;
  for v_alloc in select * from jsonb_array_elements(coalesce(p_body -> 'allocations', '[]'::jsonb))
  loop
    v_alloc_sum := v_alloc_sum + (v_alloc ->> 'amountPaise')::bigint;
  end loop;
  if v_kind = 'payment' and v_alloc_sum is distinct from v_amount then
    raise exception 'allocations must add up to the payment' using errcode = '22023';
  end if;
  if v_kind = 'advance' and v_alloc_sum <> 0 then
    raise exception 'an advance is not allocated to a bill' using errcode = '22023';
  end if;
  perform billing.assert_cash_ceiling(p_tenant_id, v_account.patient_id, v_account.branch_id, v_cash);
  v_receipt := billing.assign_number(p_tenant_id, v_account.branch_id, 'receipt');
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, counter_session_id)
  values (p_tenant_id, v_account.id, v_receipt, p_idem, v_kind, v_amount, v_session)
  returning id into v_payment;
  for v_tender in select * from jsonb_array_elements(p_body -> 'tenders')
  loop
    insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, reference)
    values (p_tenant_id, v_payment, v_tender ->> 'mode', (v_tender ->> 'amountPaise')::bigint, nullif(v_tender ->> 'reference', ''));
  end loop;
  for v_alloc in select * from jsonb_array_elements(coalesce(p_body -> 'allocations', '[]'::jsonb))
  loop
    insert into billing.allocation (tenant_id, payment_id, bill_id, amount_paise)
    values (p_tenant_id, v_payment, (v_alloc ->> 'billId')::uuid, (v_alloc ->> 'amountPaise')::bigint);
  end loop;
  return billing.receipt_json(v_payment);
end;
$$;

create or replace function billing.record_payment(p_tenant_id uuid, p_idem uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_branch uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select branch_id into v_branch from billing.billing_account
  where id = (p_body ->> 'accountId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  if v_branch is null then
    -- Replay of a key whose account is hidden still returns the original receipt when visible.
    if exists (select 1 from billing.payment where tenant_id = p_tenant_id and idempotency_key = p_idem and not is_deleted) then
      return billing.collect_payment(p_tenant_id, p_idem, p_body);
    end if;
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_branch);
  return billing.collect_payment(p_tenant_id, p_idem, p_body);
end;
$$;

create or replace function billing.insert_refund(
  p_tenant_id uuid, p_payment_id uuid, p_amount bigint, p_mode text, p_reference text, p_approval uuid, p_idem uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.payment%rowtype;
  v_account billing.billing_account%rowtype;
  v_refunded bigint;
  v_id uuid;
  v_receipt text;
  v_digital boolean;
begin
  if not billing.bypass_acl()
     and not identity.has_tenant_permission(p_tenant_id, 'billing.refund')
     and not identity.has_tenant_permission(p_tenant_id, 'billing.approve') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_src from billing.payment where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted and kind <> 'refund';
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  select coalesce(sum(amount_paise), 0) into v_refunded
  from billing.payment where refund_of_payment_id = p_payment_id and not is_deleted;
  if p_amount is null or p_amount <= 0 or p_amount > v_src.amount_paise - v_refunded then
    raise exception 'refund exceeds the amount still refundable' using errcode = '22023';
  end if;
  select * into v_account from billing.billing_account where id = v_src.account_id;
  v_digital := exists (
    select 1 from billing.payment_tender t
    where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  if p_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id) and not billing.bypass_acl() then
    raise exception 'a cash refund of a digital payment needs a manager' using errcode = '42501';
  end if;
  if p_mode is null then
    select mode into p_mode from billing.payment_tender
    where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  v_receipt := billing.assign_number(p_tenant_id, v_account.branch_id, 'receipt');
  insert into billing.payment (
    tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, refund_of_payment_id, approval_id)
  values (p_tenant_id, v_src.account_id, v_receipt, p_idem, 'refund', p_amount, p_payment_id, p_approval)
  returning id into v_id;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, reference)
  values (p_tenant_id, v_id, p_mode, p_amount, p_reference);
  return v_id;
end;
$$;

create or replace function billing.request_refund(p_tenant_id uuid, p_payment_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.payment%rowtype;
  v_amount bigint := (p_body ->> 'amountPaise')::bigint;
  v_mode text := nullif(p_body ->> 'mode', '');
  v_approval uuid;
  v_percent integer;
  v_id uuid;
  v_digital boolean;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.refund');
  select * into v_src from billing.payment where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted and kind <> 'refund';
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if v_amount is null then
    v_amount := v_src.amount_paise;
  end if;
  v_percent := case when v_src.amount_paise > 0 then round(v_amount * 10000.0 / v_src.amount_paise)::integer else null end;
  if v_mode is null then
    select mode into v_mode from billing.payment_tender where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  v_digital := exists (
    select 1 from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  if billing.within_limit(p_tenant_id, 'refund', v_amount, v_percent)
     and not (v_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id)) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(),
      jsonb_build_object('paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode, 'reference', p_body ->> 'reference'))
    returning id into v_approval;
    v_id := billing.insert_refund(p_tenant_id, p_payment_id, v_amount, v_mode, nullif(p_body ->> 'reference', ''), v_approval, gen_random_uuid());
    return billing.receipt_json(v_id);
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), 'pending',
    jsonb_build_object('paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode, 'reference', p_body ->> 'reference'))
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending');
end;
$$;

-- --------------------------------------------------------------------- approvals ----
create or replace function billing.request_discount(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_kind text := p_body ->> 'kind';
  v_value bigint := (p_body ->> 'value')::bigint;
  v_line uuid := nullif(p_body ->> 'billLineId', '')::uuid;
  v_base bigint;
  v_amount bigint;
  v_percent integer;
  v_approval uuid;
  v_reason text := btrim(p_body ->> 'reasonCode');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.discount_request');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_bill.status <> 'draft' then
    raise exception 'discounts are requested on a draft bill' using errcode = '55000';
  end if;
  if v_reason is null or v_kind not in ('percent_bp', 'flat_paise') or v_value is null or v_value <= 0 then
    raise exception 'kind, value and reasonCode are required' using errcode = '22023';
  end if;
  if v_line is null then
    v_base := billing.bill_gross(p_bill_id);
  else
    select billing.line_net(l.quantity, l.unit_price_paise) + billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp)
    into v_base from billing.bill_line l where l.id = v_line and l.bill_id = p_bill_id and not l.is_deleted;
  end if;
  if v_base is null or v_base <= 0 then
    raise exception 'nothing to discount' using errcode = '22023';
  end if;
  if v_kind = 'flat_paise' then
    v_amount := v_value;
    v_percent := round(v_value * 10000.0 / v_base)::integer;
  else
    v_percent := v_value::integer;
    v_amount := round(v_base * v_value / 10000.0)::bigint;
  end if;
  if v_amount <= 0 or v_amount > v_base then
    raise exception 'discount is outside the bill' using errcode = '22023';
  end if;
  if billing.within_limit(p_tenant_id, 'discount', v_amount, v_percent) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'discount', 'bill', p_bill_id, v_amount, v_percent, audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(),
      jsonb_build_object('billId', p_bill_id, 'billLineId', v_line, 'kind', v_kind, 'value', v_value, 'reasonCode', v_reason))
    returning id into v_approval;
    insert into billing.discount (tenant_id, bill_id, bill_line_id, kind, value, reason_code, approval_id)
    values (p_tenant_id, p_bill_id, v_line, v_kind, v_value, v_reason, v_approval);
    return billing.bill_json(p_bill_id) || jsonb_build_object('approvalId', v_approval, 'status', 'approved');
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'discount', 'bill', p_bill_id, v_amount, v_percent, audit.session_actor_id(), 'pending',
    jsonb_build_object('billId', p_bill_id, 'billLineId', v_line, 'kind', v_kind, 'value', v_value, 'reasonCode', v_reason))
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending', 'amountPaise', v_amount, 'percentBp', v_percent);
end;
$$;

create or replace function billing.decide_approval(p_tenant_id uuid, p_approval_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_req billing.approval_request%rowtype;
  v_status text := p_body ->> 'status';
  v_refund uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.approve');
  select * into v_req from billing.approval_request
  where id = p_approval_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_req.id is null then
    raise exception 'approval not found' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'approval is already decided' using errcode = '55000';
  end if;
  if v_status not in ('approved', 'rejected') then
    raise exception 'status must be approved or rejected' using errcode = '22023';
  end if;
  if v_status = 'approved' and not billing.within_limit(p_tenant_id, v_req.action, v_req.amount_paise, v_req.percent_bp) then
    raise exception 'outside your approval limit' using errcode = '42501';
  end if;
  update billing.approval_request
  set status = v_status, approver_id = audit.session_actor_id(), decided_at = pg_catalog.now(), note = nullif(p_body ->> 'note', '')
  where id = p_approval_id;
  if v_status = 'approved' and v_req.action = 'discount' then
    insert into billing.discount (tenant_id, bill_id, bill_line_id, kind, value, reason_code, approval_id)
    values (
      p_tenant_id, (v_req.payload ->> 'billId')::uuid, nullif(v_req.payload ->> 'billLineId', '')::uuid,
      v_req.payload ->> 'kind', (v_req.payload ->> 'value')::bigint, v_req.payload ->> 'reasonCode', p_approval_id);
    return billing.bill_json((v_req.payload ->> 'billId')::uuid);
  end if;
  if v_status = 'approved' and v_req.action = 'refund' then
    v_refund := billing.insert_refund(
      p_tenant_id, (v_req.payload ->> 'paymentId')::uuid, (v_req.payload ->> 'amountPaise')::bigint,
      v_req.payload ->> 'mode', nullif(v_req.payload ->> 'reference', ''), p_approval_id, gen_random_uuid());
    return billing.receipt_json(v_refund);
  end if;
  return jsonb_build_object('approvalId', p_approval_id, 'status', v_status, 'approverId', audit.session_actor_id());
end;
$$;

create or replace function billing.list_approvals(p_tenant_id uuid, p_status text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'action', r.action, 'status', r.status, 'amountPaise', r.amount_paise,
      'percentBp', r.percent_bp, 'requestedBy', r.requested_by, 'approverId', r.approver_id,
      'subjectType', r.subject_type, 'subjectId', r.subject_id, 'payload', r.payload, 'note', r.note
    ) order by r.created_on)
    from billing.approval_request r
    where r.tenant_id = p_tenant_id and not r.is_deleted
      and (p_status is null or r.status = p_status)
  ), '[]'::jsonb);
end;
$$;

-- --------------------------------------------------------------------- counter ----
create or replace function billing.open_counter(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_branch uuid := (p_body ->> 'branchId')::uuid;
  v_id uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, v_branch);
  insert into billing.counter (tenant_id, branch_id, name)
  values (p_tenant_id, v_branch, btrim(p_body ->> 'name'))
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function billing.open_session(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_counter billing.counter%rowtype;
  v_id uuid;
  v_day date;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_counter from billing.counter
  where id = (p_body ->> 'counterId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  if v_counter.id is null then
    raise exception 'counter not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_counter.branch_id);
  v_day := identity.branch_local_date_v1(v_counter.branch_id, pg_catalog.now());
  insert into billing.counter_session (tenant_id, counter_id, cashier_id, business_date, opening_float_paise)
  values (p_tenant_id, v_counter.id, audit.session_actor_id(), v_day, coalesce((p_body ->> 'openingFloatPaise')::bigint, 0))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'businessDate', v_day);
end;
$$;

create or replace function billing.close_session(p_tenant_id uuid, p_session_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_session billing.counter_session%rowtype;
  v_expected bigint;
  v_counted bigint := (p_body ->> 'countedCashPaise')::bigint;
  v_variance bigint;
  v_approval uuid := nullif(p_body ->> 'approvalId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_session from billing.counter_session
  where id = p_session_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_session.id is null then
    raise exception 'session not found' using errcode = 'P0002';
  end if;
  if v_session.status <> 'open' then
    raise exception 'session is not open' using errcode = '55000';
  end if;
  select v_session.opening_float_paise + coalesce(sum(
    case when p.kind = 'refund' then -t.amount_paise else t.amount_paise end
  ), 0) into v_expected
  from billing.payment p
  join billing.payment_tender t on t.payment_id = p.id and t.mode = 'cash' and not t.is_deleted
  where p.counter_session_id = p_session_id and not p.is_deleted;
  v_variance := coalesce(v_counted, 0) - coalesce(v_expected, 0);
  if v_variance <> 0 and (
    v_approval is null
    or not exists (
      select 1 from billing.approval_request a
      where a.id = v_approval and a.tenant_id = p_tenant_id and a.action = 'cash_variance'
        and a.status = 'approved' and a.amount_paise >= abs(v_variance) and not a.is_deleted)
  ) then
    raise exception 'a cash variance needs an approved override' using errcode = '42501';
  end if;
  insert into billing.counter_close (tenant_id, counter_session_id, mode, counted_paise, variance_approval_id, closed_by)
  values (p_tenant_id, p_session_id, 'cash', coalesce(v_counted, 0), v_approval, audit.session_actor_id());
  update billing.counter_session set status = 'closed', closed_at = pg_catalog.now() where id = p_session_id;
  return jsonb_build_object('id', p_session_id, 'expectedCashPaise', v_expected, 'countedCashPaise', v_counted, 'variancePaise', v_variance, 'status', 'closed');
end;
$$;

create or replace function billing.reconcile_session(p_tenant_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.counter_reconcile');
  update billing.counter_session set status = 'reconciled'
  where id = p_session_id and tenant_id = p_tenant_id and status = 'closed' and not is_deleted;
  if not found then
    raise exception 'closed session not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p_session_id, 'status', 'reconciled');
end;
$$;

create or replace function billing.day_end(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sessionId', s.id, 'counterId', s.counter_id, 'cashierId', s.cashier_id,
      'status', s.status, 'openingFloatPaise', s.opening_float_paise,
      'countedCashPaise', c.counted_paise, 'businessDate', s.business_date
    ) order by s.opened_at)
    from billing.counter_session s
    join billing.counter k on k.id = s.counter_id
    left join billing.counter_close c on c.counter_session_id = s.id and c.mode = 'cash' and not c.is_deleted
    where s.tenant_id = p_tenant_id and k.branch_id = p_branch_id and s.business_date = p_on and not s.is_deleted
  ), '[]'::jsonb);
end;
$$;

create or replace function billing.patient_summary(p_tenant_id uuid, p_patient_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_advance bigint;
  v_accounts jsonb;
  v_bills jsonb;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_patient(p_tenant_id, p_patient_id);
  select advance_paise into v_advance from billing.patient_advance_v1
  where tenant_id = p_tenant_id and patient_id = p_patient_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'branchId', a.branch_id, 'accountType', a.account_type,
    'status', a.status, 'sourceRefType', a.source_ref_type, 'sourceRefId', a.source_ref_id
  )), '[]'::jsonb) into v_accounts
  from billing.billing_account a
  where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id and not a.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'billNo', b.bill_no, 'status', b.status, 'billKind', b.bill_kind,
    'totalPaise', t.total_paise, 'duePaise', bal.due_paise
  )), '[]'::jsonb) into v_bills
  from billing.bill b
  join billing.billing_account a on a.id = b.account_id
  left join billing.bill_totals_v1 t on t.bill_id = b.id
  left join billing.bill_balance_v1 bal on bal.bill_id = b.id
  where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id and not b.is_deleted and b.status <> 'cancelled_draft';
  return jsonb_build_object(
    'patientId', p_patient_id, 'advancePaise', coalesce(v_advance, 0),
    'accounts', v_accounts, 'bills', v_bills);
end;
$$;

-- --------------------------------------------------------------------- check-in ----
create or replace function billing.ensure_draft(p_tenant_id uuid, p_appointment_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ref record;
  v_account uuid;
  v_bill uuid;
  v_status text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_ref from appointment.appointment_billing_ref_v1(p_tenant_id, p_appointment_id);
  if v_ref.patient_id is null then
    raise exception 'appointment not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_ref.branch_id);
  perform billing.ensure_defaults(p_tenant_id);
  select a.id into v_account from billing.billing_account a
  where a.tenant_id = p_tenant_id and a.source_ref_type = 'appointment' and a.source_ref_id = p_appointment_id and not a.is_deleted;
  if v_account is null and v_ref.status in ('checked_in', 'in_consultation', 'completed') then
    insert into billing.billing_account (tenant_id, patient_id, branch_id, account_type, source_ref_type, source_ref_id)
    values (p_tenant_id, v_ref.patient_id, v_ref.branch_id, 'op_visit', 'appointment', p_appointment_id)
    returning id into v_account;
  end if;
  if v_account is null then
    raise exception 'appointment is not checked in' using errcode = '55000';
  end if;
  select b.id, b.status into v_bill, v_status from billing.bill b
  where b.account_id = v_account and b.bill_kind = 'final' and not b.is_deleted
  order by b.created_on limit 1;
  if v_ref.status in ('cancelled', 'no_show') then
    if v_bill is not null and v_status = 'draft'
       and not exists (select 1 from billing.bill_line l where l.bill_id = v_bill and not l.is_deleted) then
      update billing.bill set status = 'cancelled_draft' where id = v_bill;
    end if;
    return jsonb_build_object('accountId', v_account, 'billId', v_bill, 'status', 'cancelled');
  end if;
  if v_bill is null then
    insert into billing.bill (tenant_id, account_id, bill_kind)
    values (p_tenant_id, v_account, 'final')
    returning id into v_bill;
  end if;
  if v_status is null or v_status = 'draft' then
    if not exists (select 1 from billing.bill_line l where l.bill_id = v_bill and not l.is_deleted) then
      perform billing.add_line(p_tenant_id, v_bill, jsonb_build_object('code', 'CONSULT', 'practitionerId', v_ref.practitioner_id));
    end if;
  end if;
  return billing.bill_json(v_bill);
end;
$$;

create or replace function billing.repoint_patient(p_tenant_id uuid, p_from uuid, p_to uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not identity.has_tenant_permission(p_tenant_id, 'billing.bill') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform billing.assert_patient(p_tenant_id, p_to);
  update billing.billing_account set patient_id = p_to
  where tenant_id = p_tenant_id and patient_id = p_from and not is_deleted;
end;
$$;

create or replace function billing.consume_event(p_event_id uuid, p_event_type text, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := (p_payload ->> 'tenant_id')::uuid;
  v_appointment uuid := nullif(p_payload ->> 'appointment_id', '')::uuid;
begin
  perform billing.assert_permission(v_tenant, 'billing.bill');
  insert into billing.inbox (event_id, tenant_id, event_type)
  values (p_event_id, v_tenant, p_event_type)
  on conflict (event_id) do nothing;
  if not found then
    return jsonb_build_object('duplicate', true);
  end if;
  if p_event_type in ('appointment.checked_in', 'appointment.checked_in.v1', 'appointment.cancelled', 'appointment.cancelled.v1') then
    return billing.ensure_draft(v_tenant, v_appointment) || jsonb_build_object('duplicate', false);
  end if;
  if p_event_type = 'patient.merged' then
    perform billing.repoint_patient(v_tenant, (p_payload ->> 'duplicate_patient_id')::uuid, (p_payload ->> 'survivor_patient_id')::uuid);
  end if;
  return jsonb_build_object('duplicate', false);
end;
$$;

-- --------------------------------------------------------------------- links ----
create or replace function billing.create_payment_link(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_order text := gen_random_uuid()::text;
  v_channel text := coalesce(p_body ->> 'channel', 'link');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  if not exists (select 1 from billing.bill b where b.id = p_bill_id and b.tenant_id = p_tenant_id and b.status = 'finalized' and not b.is_deleted) then
    raise exception 'finalized bill not found' using errcode = 'P0002';
  end if;
  if v_channel not in ('whatsapp', 'sms', 'qr', 'link') then
    raise exception 'channel must be whatsapp, sms, qr or link' using errcode = '22023';
  end if;
  insert into billing.payment_link (tenant_id, bill_id, channel, provider_order_id, expires_at)
  values (p_tenant_id, p_bill_id, v_channel, v_order, pg_catalog.now() + interval '2 days')
  returning id into v_id;
  return jsonb_build_object(
    'id', v_id, 'providerOrderId', v_order, 'channel', v_channel,
    'path', '/api/v1/billing-public/links/' || v_order);
end;
$$;

create or replace function billing.public_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link billing.payment_link%rowtype;
  v_doc jsonb;
begin
  select * into v_link from billing.payment_link
  where provider_order_id = p_token and not is_deleted;
  if v_link.id is null or v_link.expires_at < pg_catalog.now() then
    raise exception 'link not found' using errcode = 'P0002';
  end if;
  v_doc := billing.bill_json(v_link.bill_id);
  return v_doc || jsonb_build_object('linkStatus', v_link.status, 'channel', v_link.channel);
end;
$$;

create or replace function billing.apply_webhook(p_provider text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event text := p_body ->> 'eventId';
  v_order text := p_body ->> 'providerOrderId';
  v_status text := coalesce(p_body ->> 'status', '');
  v_amount bigint := (p_body ->> 'amountPaise')::bigint;
  v_link billing.payment_link%rowtype;
  v_due bigint;
  v_account uuid;
  v_idem uuid;
  v_receipt jsonb;
begin
  if v_event is null or v_order is null then
    raise exception 'eventId and providerOrderId are required' using errcode = '22023';
  end if;
  if exists (
    select 1 from billing.provider_webhook_event e
    where e.provider = p_provider and e.event_id = v_event and not e.is_deleted
  ) then
    return jsonb_build_object('duplicate', true);
  end if;
  select * into v_link from billing.payment_link where provider_order_id = v_order and not is_deleted;
  if v_link.id is null then
    raise exception 'payment link not found' using errcode = 'P0002';
  end if;
  if v_status is distinct from 'paid' then
    insert into billing.provider_webhook_event (tenant_id, provider, event_id)
    values (v_link.tenant_id, p_provider, v_event);
    return jsonb_build_object('duplicate', false, 'applied', false);
  end if;
  select due_paise, account_id into v_due, v_account
  from billing.bill_balance_v1
  where bill_id = v_link.bill_id;
  if v_amount is distinct from v_due or v_due is null or v_due <= 0 then
    raise exception 'webhook amount does not match the amount due' using errcode = '22023';
  end if;
  v_idem := md5('webhook:' || p_provider || ':' || v_event)::uuid;
  v_receipt := billing.collect_payment(v_link.tenant_id, v_idem, jsonb_build_object(
    'accountId', v_account, 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_amount, 'reference', v_order)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_link.bill_id, 'amountPaise', v_amount))));
  update billing.payment_link set status = 'paid' where id = v_link.id;
  insert into billing.provider_webhook_event (tenant_id, provider, event_id)
  values (v_link.tenant_id, p_provider, v_event);
  return v_receipt || jsonb_build_object('duplicate', false, 'applied', true);
end;
$$;

-- --------------------------------------------------------------------- grants ----
grant usage on schema identity, patient, appointment, auth to hms_svc_billing;
grant execute on function auth.uid() to hms_svc_billing;
grant execute on function auth.jwt() to hms_svc_billing;
grant execute on function audit.session_actor_id() to hms_svc_billing;
grant execute on function identity.current_tenant_ids() to hms_svc_billing;
grant execute on function identity.current_branch_ids(uuid) to hms_svc_billing;
grant execute on function identity.has_tenant_permission(uuid, text) to hms_svc_billing;
grant execute on function identity.branch_exists_v1(uuid, uuid) to hms_svc_billing;
grant execute on function identity.branch_local_date_v1(uuid, timestamptz) to hms_svc_billing;
grant execute on function identity.branch_time_zone_v1(uuid) to hms_svc_billing;
grant execute on function identity.my_tenant_grant_v1(uuid) to hms_svc_billing;
grant execute on function identity.my_active_context() to hms_svc_billing;
grant execute on function patient.patient_exists_v1(uuid, uuid) to hms_svc_billing;

revoke all on all functions in schema billing from public, anon, authenticated;
grant execute on all functions in schema billing to hms_svc_billing;
-- The public receipt and the provider webhook run as anon (no JWT). Both are security definer
-- and look up an unguessable token; they do not receive table grants.
grant execute on function billing.public_link(text) to anon;
grant execute on function billing.apply_webhook(text, jsonb) to anon;

revoke all on billing.bill_totals_v1, billing.bill_balance_v1, billing.patient_advance_v1 from public, anon, authenticated;
grant select on billing.bill_totals_v1, billing.bill_balance_v1, billing.patient_advance_v1 to hms_svc_billing;

comment on function billing.public_link(text) is
  'Unauthenticated receipt for a share token. Returns ids and amounts only.';
comment on function billing.apply_webhook(text, jsonb) is
  'Provider webhook. Deduped on (provider, event_id). The API checks the shared secret before calling this.';
