-- GST Rule 46 supplier block, CGST/SGST vs IGST, bill list, cancel/no-show refunds,
-- and maker-checker above a tenant threshold. Existing billing and branch settings only.
-- cross-schema: approved (billing reads identity.branch_bill_header_v1; the appointment
-- status trigger calls billing.ensure_draft / billing.settle_closed_visit as the bill owner).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- --------------------------------------------------------------------- columns ----
alter table billing.branch_profile
  add column gstin text,
  add column legal_name text;
alter table billing.branch_profile add constraint branch_profile_gstin
  check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');
alter table billing.branch_profile add constraint branch_profile_legal_name
  check (legal_name is null or (char_length(legal_name) between 1 and 200 and legal_name = btrim(legal_name)));
comment on column billing.branch_profile.gstin is
  'Supplier GSTIN for this branch (15 characters). Snapshotted onto the bill at finalize.';
comment on column billing.branch_profile.legal_name is
  'Legal name printed on bills. The branch name is used when this is empty.';

alter table billing.bill
  add column supplier_gstin text,
  add column supplier_state_code text,
  add column pos_state_code text,
  add column supplier_name text,
  add column supplier_address text;
alter table billing.bill add constraint bill_supplier_gstin
  check (supplier_gstin is null or supplier_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');
alter table billing.bill add constraint bill_supplier_state
  check (supplier_state_code is null or supplier_state_code ~ '^[0-9]{2}$');
alter table billing.bill add constraint bill_pos_state
  check (pos_state_code is null or pos_state_code ~ '^[0-9]{2}$');
alter table billing.bill add constraint bill_supplier_gstin_state
  check (supplier_gstin is null or supplier_state_code is null or supplier_state_code = left(supplier_gstin, 2));
alter table billing.bill add constraint bill_supplier_name
  check (supplier_name is null or (char_length(supplier_name) between 1 and 200 and supplier_name = btrim(supplier_name)));
alter table billing.bill add constraint bill_supplier_address
  check (supplier_address is null or (char_length(supplier_address) between 1 and 300 and supplier_address = btrim(supplier_address)));
comment on column billing.bill.supplier_gstin is
  'Supplier GSTIN at finalize. Later profile edits do not rewrite an issued bill.';
comment on column billing.bill.pos_state_code is
  'Place of supply (2-digit state code). Defaults to the supplier state. A different state is IGST.';

alter table billing.payment
  add column credit_note_id uuid references billing.bill (id);
alter table billing.payment add constraint payment_credit_note_kind
  check (credit_note_id is null or kind = 'refund');
comment on column billing.payment.credit_note_id is
  'GST credit note issued with this refund. Set on insert; payments are immutable.';

-- --------------------------------------------------------------------- settings ----
create table billing.approval_settings (
  tenant_id uuid primary key,
  maker_checker_threshold_paise bigint not null default 20000,
  cancel_refund_pct_bp integer not null default 10000,
  no_show_refund_pct_bp integer not null default 0,
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint approval_settings_threshold check (maker_checker_threshold_paise >= 0),
  constraint approval_settings_cancel_pct check (cancel_refund_pct_bp between 0 and 10000),
  constraint approval_settings_noshow_pct check (no_show_refund_pct_bp between 0 and 10000)
);
comment on table billing.approval_settings is
  'One row per tenant. Amounts strictly above the threshold need a different approver. Cancel refunds the paid share (default 100%); no-show defaults to none.';

create trigger approval_settings_audit_columns before insert or update on billing.approval_settings
  for each row execute function audit.stamp_audit_columns();
create trigger approval_settings_tenant_immutable before update on billing.approval_settings
  for each row execute function audit.prevent_tenant_change();
create trigger approval_settings_audit_log after insert or update or delete on billing.approval_settings
  for each row execute function audit.log_row_change();
alter table billing.approval_settings enable row level security;
grant select, insert, update on billing.approval_settings to hms_svc_billing;
revoke delete on billing.approval_settings from hms_svc_billing, anon, authenticated, public;
create policy approval_settings_tenant on billing.approval_settings for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));

insert into billing.approval_settings (tenant_id)
select t.id from identity.tenants t
on conflict (tenant_id) do nothing;

-- --------------------------------------------------------------------- money ----
-- Intra-state (or an unknown state) splits the tax in half; an odd paise goes to CGST.
-- Different supplier and place-of-supply states put the whole tax on IGST.
-- A missing place of supply, or a missing supplier state, is intra-state: CGST and SGST, never IGST.
-- Odd paise on a line go to CGST. A multi-line bill sums those line splits and does not split the total again.
create or replace function billing.tax_split(p_tax bigint, p_rate integer, p_supplier text, p_pos text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_supplier is not null and p_pos is not null and p_supplier is distinct from p_pos then
      jsonb_build_object(
        'cgstPaise', 0, 'sgstPaise', 0, 'igstPaise', coalesce(p_tax, 0),
        'cgstRateBp', 0, 'sgstRateBp', 0, 'igstRateBp', coalesce(p_rate, 0))
    else jsonb_build_object(
      'cgstPaise', coalesce(p_tax, 0) - coalesce(p_tax, 0) / 2,
      'sgstPaise', coalesce(p_tax, 0) / 2,
      'igstPaise', 0,
      'cgstRateBp', coalesce(p_rate, 0) - coalesce(p_rate, 0) / 2,
      'sgstRateBp', coalesce(p_rate, 0) / 2,
      'igstRateBp', 0)
  end
$$;

create or replace function billing.needs_checker(p_tenant_id uuid, p_amount bigint)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(p_amount, 0) > coalesce((
    select s.maker_checker_threshold_paise
    from billing.approval_settings s
    where s.tenant_id = p_tenant_id and not s.is_deleted
  ), 20000)
$$;

create or replace function billing.visit_refund_pct(p_tenant_id uuid, p_status text)
returns integer
language sql
stable
set search_path = ''
as $$
  select case p_status
    when 'no_show' then coalesce((
      select s.no_show_refund_pct_bp from billing.approval_settings s
      where s.tenant_id = p_tenant_id and not s.is_deleted), 0)
    else coalesce((
      select s.cancel_refund_pct_bp from billing.approval_settings s
      where s.tenant_id = p_tenant_id and not s.is_deleted), 10000)
  end
$$;

-- cross-schema: approved (published v1; billing invoice header. Name and address only.)
create or replace function identity.branch_bill_header_v1(p_tenant_id uuid, p_branch_id uuid)
returns table (name text, address text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- anon has no execute. A public receipt reaches this only through billing.public_link,
  -- which runs as the owner with the session role still anon and no tenant claim.
  if pg_catalog.current_setting('role', true) is distinct from 'anon'
     and (auth.uid() is not null or pg_catalog.current_setting('role', true) = 'authenticated')
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select b.name, b.address
  from identity.branches b
  where b.tenant_id = p_tenant_id and b.id = p_branch_id and not b.is_deleted;
end;
$$;
comment on function identity.branch_bill_header_v1(uuid, uuid) is
  'v1 (published by identity): branch name and address for a bill. Empty when missing. No GSTIN.';
revoke all on function identity.branch_bill_header_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function identity.branch_bill_header_v1(uuid, uuid) to service_role, hms_svc_billing;

create or replace function billing.set_branch_profile(p_tenant_id uuid, p_branch_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gstin text;
  v_legal text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  if p_body ? 'gstin' then
    v_gstin := nullif(upper(btrim(coalesce(p_body ->> 'gstin', ''))), '');
    if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'GSTIN must be 15 characters' using errcode = '22023';
    end if;
  end if;
  if p_body ? 'legalName' then
    v_legal := nullif(btrim(coalesce(p_body ->> 'legalName', '')), '');
    if v_legal is not null and char_length(v_legal) > 200 then
      raise exception 'legal name must be 200 characters or fewer' using errcode = '22023';
    end if;
  end if;
  insert into billing.branch_profile (tenant_id, branch_id, doc_prefix, gstin, legal_name)
  values (
    p_tenant_id, p_branch_id, 'OP',
    case when p_body ? 'gstin' then v_gstin else null end,
    case when p_body ? 'legalName' then v_legal else null end)
  on conflict (tenant_id, branch_id) do update set
    gstin = case when p_body ? 'gstin' then excluded.gstin else billing.branch_profile.gstin end,
    legal_name = case when p_body ? 'legalName' then excluded.legal_name else billing.branch_profile.legal_name end;
  return billing.branch_profile_json(p_tenant_id, p_branch_id);
end;
$$;

create or replace function billing.branch_profile_json(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row billing.branch_profile%rowtype;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  select * into v_row from billing.branch_profile
  where tenant_id = p_tenant_id and branch_id = p_branch_id and not is_deleted;
  return jsonb_build_object(
    'branchId', p_branch_id,
    'docPrefix', v_row.doc_prefix,
    'gstin', v_row.gstin,
    'legalName', v_row.legal_name);
end;
$$;

create or replace function billing.set_place_of_supply(p_tenant_id uuid, p_bill_id uuid, p_state text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_state text := btrim(coalesce(p_state, ''));
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select status into v_status from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_status is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'place of supply is set on a draft bill' using errcode = '55000';
  end if;
  if v_state !~ '^[0-9]{2}$' then
    raise exception 'place of supply must be a 2-digit state code' using errcode = '22023';
  end if;
  update billing.bill set pos_state_code = v_state where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

create or replace function billing.approval_settings_json(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row billing.approval_settings%rowtype;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  select * into v_row from billing.approval_settings
  where tenant_id = p_tenant_id and not is_deleted;
  return jsonb_build_object(
    'makerCheckerThresholdPaise', coalesce(v_row.maker_checker_threshold_paise, 20000),
    'cancelRefundPctBp', coalesce(v_row.cancel_refund_pct_bp, 10000),
    'noShowRefundPctBp', coalesce(v_row.no_show_refund_pct_bp, 0));
end;
$$;

create or replace function billing.set_approval_settings(p_tenant_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_threshold bigint;
  v_cancel integer;
  v_noshow integer;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.approve');
  insert into billing.approval_settings (tenant_id) values (p_tenant_id)
  on conflict (tenant_id) do nothing;
  if p_body ? 'makerCheckerThresholdPaise' then
    v_threshold := (p_body ->> 'makerCheckerThresholdPaise')::bigint;
    if v_threshold is null or v_threshold < 0 then
      raise exception 'maker-checker threshold must be zero or more' using errcode = '22023';
    end if;
  end if;
  if p_body ? 'cancelRefundPctBp' then
    v_cancel := (p_body ->> 'cancelRefundPctBp')::integer;
    if v_cancel is null or v_cancel < 0 or v_cancel > 10000 then
      raise exception 'cancel refund percent must be between 0 and 10000' using errcode = '22023';
    end if;
  end if;
  if p_body ? 'noShowRefundPctBp' then
    v_noshow := (p_body ->> 'noShowRefundPctBp')::integer;
    if v_noshow is null or v_noshow < 0 or v_noshow > 10000 then
      raise exception 'no-show refund percent must be between 0 and 10000' using errcode = '22023';
    end if;
  end if;
  update billing.approval_settings s set
    maker_checker_threshold_paise = case when p_body ? 'makerCheckerThresholdPaise' then v_threshold else s.maker_checker_threshold_paise end,
    cancel_refund_pct_bp = case when p_body ? 'cancelRefundPctBp' then v_cancel else s.cancel_refund_pct_bp end,
    no_show_refund_pct_bp = case when p_body ? 'noShowRefundPctBp' then v_noshow else s.no_show_refund_pct_bp end
  where s.tenant_id = p_tenant_id;
  return billing.approval_settings_json(p_tenant_id);
end;
$$;

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
  insert into billing.approval_settings (tenant_id) values (p_tenant_id)
  on conflict (tenant_id) do nothing;
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
  v_payments jsonb;
  v_live_gstin text;
  v_legal text;
  v_branch_name text;
  v_branch_address text;
  v_gstin text;
  v_state text;
  v_pos text;
  v_name text;
  v_address text;
  v_cgst bigint;
  v_sgst bigint;
  v_igst bigint;
begin
  select * into v_bill from billing.bill where id = p_bill_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  select * into v_totals from billing.bill_totals_v1 where bill_id = p_bill_id;
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  select bp.gstin, bp.legal_name into v_live_gstin, v_legal
  from billing.branch_profile bp
  where bp.tenant_id = v_bill.tenant_id and bp.branch_id = v_account.branch_id and not bp.is_deleted;
  select h.name, h.address into v_branch_name, v_branch_address
  from identity.branch_bill_header_v1(v_bill.tenant_id, v_account.branch_id) h;
  v_gstin := coalesce(v_bill.supplier_gstin, v_live_gstin);
  v_state := coalesce(v_bill.supplier_state_code, left(v_gstin, 2));
  v_pos := coalesce(v_bill.pos_state_code, v_state);
  v_name := coalesce(v_bill.supplier_name, nullif(btrim(v_legal), ''), v_branch_name);
  v_address := coalesce(v_bill.supplier_address, v_branch_address);
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', l.id, 'lineNo', l.line_no, 'serviceItemId', l.service_item_id,
      'code', si.code, 'name', si.name, 'quantity', l.quantity,
      'unitPricePaise', l.unit_price_paise, 'taxRateBp', l.tax_rate_bp,
      'netPaise', billing.line_net(l.quantity, l.unit_price_paise),
      'taxPaise', billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
      'sacHsnCode', tc.sac_hsn_code,
      'practitionerId', l.practitioner_id,
      'locked', billing.line_is_locked(l.id)
    ) || billing.tax_split(
      billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
      l.tax_rate_bp, v_state, v_pos)
    order by l.line_no), '[]'::jsonb),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'cgstPaise')::bigint), 0),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'sgstPaise')::bigint), 0),
    coalesce(sum((billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp, v_state, v_pos) ->> 'igstPaise')::bigint), 0)
  into v_lines, v_cgst, v_sgst, v_igst
  from billing.bill_line l
  join billing.service_item si on si.id = l.service_item_id
  left join billing.tax_code tc on tc.id = si.tax_code_id
  where l.bill_id = p_bill_id and not l.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'billLineId', d.bill_line_id, 'kind', d.kind, 'value', d.value,
    'reasonCode', d.reason_code, 'approvalId', d.approval_id
  )), '[]'::jsonb) into v_discounts
  from billing.discount d
  join billing.approval_request a on a.id = d.approval_id and a.status = 'approved' and not a.is_deleted
  where d.bill_id = p_bill_id and not d.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'receiptNo', p.receipt_no, 'amountPaise', p.amount_paise,
    'refundedPaise', coalesce((
      select sum(r.amount_paise) from billing.payment r
      where r.refund_of_payment_id = p.id and not r.is_deleted), 0),
    'mode', (
      select t.mode from billing.payment_tender t
      where t.payment_id = p.id and not t.is_deleted
      order by t.amount_paise desc limit 1)
  ) order by p.received_at), '[]'::jsonb) into v_payments
  from billing.payment p
  where p.kind <> 'refund' and not p.is_deleted
    and exists (
      select 1 from billing.allocation al
      where al.payment_id = p.id and al.bill_id = p_bill_id and not al.is_deleted);
  return jsonb_build_object(
    'id', v_bill.id, 'billNo', v_bill.bill_no, 'status', v_bill.status, 'billKind', v_bill.bill_kind,
    'payerType', v_bill.payer_type, 'accountId', v_bill.account_id, 'patientId', v_account.patient_id,
    'branchId', v_account.branch_id, 'reversesBillId', v_bill.reverses_bill_id,
    'lines', v_lines, 'discounts', v_discounts, 'payments', coalesce(v_payments, '[]'::jsonb),
    'netPaise', v_totals.net_paise, 'taxPaise', v_totals.tax_paise,
    'discountPaise', v_totals.discount_paise, 'exactPaise', v_totals.exact_paise,
    'roundOffPaise', v_totals.round_off_paise, 'totalPaise', v_totals.total_paise,
    'cgstPaise', coalesce(v_cgst, 0), 'sgstPaise', coalesce(v_sgst, 0), 'igstPaise', coalesce(v_igst, 0),
    'allocatedPaise', billing.allocated_paise(p_bill_id),
    'duePaise', coalesce(v_due, v_totals.total_paise),
    'placeOfSupplyState', v_pos,
    'supplier', jsonb_build_object(
      'gstin', v_gstin, 'stateCode', v_state, 'name', v_name, 'address', v_address));
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
  v_note text;
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
  select b.bill_no into v_note from billing.bill b where b.id = v_pay.credit_note_id;
  return jsonb_build_object(
    'id', v_pay.id, 'receiptNo', v_pay.receipt_no, 'kind', v_pay.kind,
    'amountPaise', v_pay.amount_paise, 'idempotencyKey', v_pay.idempotency_key,
    'accountId', v_pay.account_id, 'counterSessionId', v_pay.counter_session_id,
    'refundOfPaymentId', v_pay.refund_of_payment_id,
    'creditNoteId', v_pay.credit_note_id, 'creditNoteNo', v_note,
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc);
end;
$$;

create or replace function billing.list_bills(
  p_tenant_id uuid, p_status text, p_branch_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  if p_branch_id is not null then
    perform billing.assert_branch(p_tenant_id, p_branch_id);
  end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb)
    from (
      select b.id, b.bill_no as "billNo", b.status, b.bill_kind as "billKind",
             a.patient_id as "patientId", a.branch_id as "branchId",
             t.total_paise as "totalPaise", bal.due_paise as "duePaise",
             b.created_on as "createdOn"
      from billing.bill b
      join billing.billing_account a on a.id = b.account_id
      left join billing.bill_totals_v1 t on t.bill_id = b.id
      left join billing.bill_balance_v1 bal on bal.bill_id = b.id
      where b.tenant_id = p_tenant_id and not b.is_deleted
        and (v_status is null or b.status = v_status)
        and (p_branch_id is null or a.branch_id = p_branch_id)
        and (p_from is null or (b.created_on at time zone identity.branch_time_zone_v1(a.branch_id))::date >= p_from)
        and (p_to is null or (b.created_on at time zone identity.branch_time_zone_v1(a.branch_id))::date <= p_to)
      order by b.created_on desc
      limit 200
    ) x
  ), '[]'::jsonb);
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
  v_gstin text;
  v_legal text;
  v_state text;
  v_pos text;
  v_name text;
  v_address text;
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
  if v_bill.reverses_bill_id is not null then
    select supplier_gstin, supplier_state_code, supplier_name, supplier_address
    into v_gstin, v_state, v_name, v_address
    from billing.bill where id = v_bill.reverses_bill_id;
    v_pos := coalesce(v_bill.pos_state_code, v_state);
  else
    select bp.gstin, bp.legal_name into v_gstin, v_legal
    from billing.branch_profile bp
    where bp.tenant_id = p_tenant_id and bp.branch_id = v_branch and not bp.is_deleted;
    select h.name, h.address into v_name, v_address
    from identity.branch_bill_header_v1(p_tenant_id, v_branch) h;
    v_name := coalesce(nullif(btrim(v_legal), ''), v_name);
    v_state := left(v_gstin, 2);
    v_pos := coalesce(v_bill.pos_state_code, v_state);
  end if;
  v_name := nullif(btrim(left(btrim(coalesce(v_name, '')), 200)), '');
  v_address := nullif(btrim(left(btrim(coalesce(v_address, '')), 300)), '');
  v_doc := billing.assign_number(p_tenant_id, v_branch,
    case when v_bill.bill_kind = 'credit_note' then 'credit_note' else 'bill' end);
  update billing.bill set
    status = 'finalized', bill_no = v_doc, finalized_at = pg_catalog.now(), finalized_by = audit.session_actor_id(),
    supplier_gstin = v_gstin, supplier_state_code = v_state, pos_state_code = v_pos,
    supplier_name = v_name, supplier_address = v_address
  where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

-- Quantity already reversed by finalized credit notes. A second note cannot credit it again.
create or replace function billing.line_credited_qty(p_line_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(-l.quantity), 0)
  from billing.bill_line l
  join billing.bill cn on cn.id = l.bill_id
  where l.reverses_line_id = p_line_id
    and not l.is_deleted and not cn.is_deleted
    and cn.bill_kind = 'credit_note' and cn.status = 'finalized'
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
  v_left numeric;
  v_n int := 0;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_src from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted and status = 'finalized' and bill_kind <> 'credit_note'
  for update;
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
    v_left := case when v_src_line.id is null then 0
      else v_src_line.quantity - billing.line_credited_qty(v_src_line.id) end;
    if v_src_line.id is null or v_qty is null or v_qty <= 0 or v_qty > v_left then
      raise exception 'credit quantity exceeds the amount not already credited' using errcode = '22023';
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

-- A refund both reverses the allocation and issues a credit note, so due does not go negative
-- and the patient is not billed again. A paid draft is finalized first so the note can cite it.
-- Clearing every allocation on a draft credits the whole bill (a partial payment on a cancel
-- must not leave the unpaid part due). A later note only credits quantity not already reversed.
create or replace function billing.credit_note_for_refund(p_tenant_id uuid, p_payment_id uuid, p_amount bigint)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_bill uuid;
  v_status text;
  v_gross bigint;
  v_line record;
  v_body jsonb := '[]'::jsonb;
  v_qty numeric;
  v_left numeric;
  v_note jsonb;
  v_allocated bigint;
  v_full boolean := false;
begin
  select al.bill_id into v_bill
  from billing.allocation al
  where al.payment_id = p_payment_id and not al.is_deleted
  group by al.bill_id
  having sum(al.amount_paise) > 0
  order by sum(al.amount_paise) desc, max(al.created_on) desc
  limit 1;
  if v_bill is null then
    return null;
  end if;
  select status into v_status from billing.bill
  where id = v_bill and tenant_id = p_tenant_id and not is_deleted
  for update;
  if v_status is null or v_status = 'cancelled_draft' then
    return null;
  end if;
  -- A partial refund of an open bill puts the money back on that bill (due goes up) and
  -- does not issue a tax invoice. A credit note is issued when the bill is already finalized,
  -- or when this refund clears every allocation so a cancelled visit is not billed again.
  if v_status = 'draft' then
    select coalesce(sum(a.amount_paise), 0) into v_allocated
    from billing.allocation a
    where a.bill_id = v_bill and not a.is_deleted;
    if p_amount is null or p_amount < v_allocated then
      return null;
    end if;
    perform billing.finalize_bill(p_tenant_id, v_bill);
    v_full := true;
  end if;
  v_gross := billing.bill_gross(v_bill);
  if v_gross is null or v_gross <= 0 or p_amount is null or p_amount <= 0 then
    return null;
  end if;
  for v_line in
    select l.id, l.quantity
    from billing.bill_line l
    where l.bill_id = v_bill and not l.is_deleted and l.quantity > 0
    order by l.line_no
  loop
    v_left := v_line.quantity - billing.line_credited_qty(v_line.id);
    if v_full then
      v_qty := v_left;
    else
      v_qty := least(v_left, round(v_line.quantity * least(p_amount, v_gross)::numeric / v_gross, 3));
    end if;
    if v_qty > 0 then
      v_body := v_body || jsonb_build_array(jsonb_build_object('lineId', v_line.id, 'quantity', v_qty));
    end if;
  end loop;
  if v_body = '[]'::jsonb then
    return null;
  end if;
  v_note := billing.create_credit_note(p_tenant_id, v_bill, jsonb_build_object('lines', v_body));
  return (v_note ->> 'id')::uuid;
end;
$$;

create or replace function billing.insert_refund(
  p_tenant_id uuid, p_payment_id uuid, p_amount bigint, p_mode text, p_reference text,
  p_approval uuid, p_idem uuid, p_session uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.payment%rowtype;
  v_account billing.billing_account%rowtype;
  v_refunded bigint;
  v_net bigint;
  v_open bigint;
  v_reverse bigint;
  v_id uuid;
  v_receipt text;
  v_digital boolean;
  v_session uuid;
  v_row record;
  v_take bigint;
  v_credit uuid;
begin
  if not billing.bypass_acl()
     and not identity.has_tenant_permission(p_tenant_id, 'billing.refund')
     and not identity.has_tenant_permission(p_tenant_id, 'billing.approve') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('billing.payment:' || p_payment_id::text, 0));
  select * into v_src from billing.payment
  where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted;
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if v_src.kind = 'refund' then
    raise exception 'a refund cannot be refunded' using errcode = '22023';
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
  v_credit := billing.credit_note_for_refund(p_tenant_id, p_payment_id, p_amount);
  select coalesce(sum(amount_paise), 0) into v_net
  from billing.allocation where payment_id = p_payment_id and not is_deleted;
  v_open := v_src.amount_paise - v_refunded - v_net;
  v_reverse := greatest(p_amount - greatest(v_open, 0), 0);
  v_session := billing.refund_session(p_tenant_id, v_account.branch_id, p_mode, v_src.counter_session_id, p_session);
  v_receipt := billing.assign_number(p_tenant_id, v_account.branch_id, 'receipt');
  insert into billing.payment (
    tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise,
    counter_session_id, refund_of_payment_id, approval_id, credit_note_id)
  values (
    p_tenant_id, v_src.account_id, v_receipt, p_idem, 'refund', p_amount,
    v_session, p_payment_id, p_approval, v_credit)
  returning id into v_id;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, reference)
  values (p_tenant_id, v_id, p_mode, p_amount, p_reference);
  for v_row in
    select al.bill_id, sum(al.amount_paise) as net
    from billing.allocation al
    where al.payment_id = p_payment_id and not al.is_deleted
    group by al.bill_id
    having sum(al.amount_paise) > 0
    order by max(al.created_on) desc, al.bill_id desc
  loop
    exit when v_reverse <= 0;
    v_take := least(v_reverse, v_row.net);
    insert into billing.allocation (tenant_id, payment_id, bill_id, amount_paise)
    values (p_tenant_id, p_payment_id, v_row.bill_id, -v_take);
    v_reverse := v_reverse - v_take;
  end loop;
  if v_reverse > 0 then
    raise exception 'refund could not be reversed against the allocations' using errcode = '55000';
  end if;
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
  v_session uuid := nullif(p_body ->> 'counterSessionId', '')::uuid;
  v_approval uuid;
  v_percent integer;
  v_id uuid;
  v_digital boolean;
  v_payload jsonb;
  v_left bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.refund');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('billing.payment:' || p_payment_id::text, 0));
  select * into v_src from billing.payment where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted;
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if v_src.kind = 'refund' then
    raise exception 'a refund cannot be refunded' using errcode = '22023';
  end if;
  if v_amount is null then
    v_amount := v_src.amount_paise;
  end if;
  v_left := v_src.amount_paise
    - coalesce((select sum(r.amount_paise) from billing.payment r
                where r.refund_of_payment_id = p_payment_id and not r.is_deleted), 0)
    - coalesce((select sum(ar.amount_paise) from billing.approval_request ar
                where ar.tenant_id = p_tenant_id and ar.action = 'refund' and ar.subject_id = p_payment_id
                  and ar.status = 'pending' and not ar.is_deleted), 0);
  if v_amount is null or v_amount <= 0 or v_amount > v_left then
    raise exception 'refund exceeds the amount still refundable' using errcode = '22023';
  end if;
  v_percent := case when v_src.amount_paise > 0 then round(v_amount * 10000.0 / v_src.amount_paise)::integer else null end;
  if v_mode is null then
    select mode into v_mode from billing.payment_tender where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode,
    'reference', p_body ->> 'reference', 'counterSessionId', v_session,
    'appointmentId', nullif(p_body ->> 'appointmentId', '')));
  v_digital := exists (
    select 1 from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  if billing.within_limit(p_tenant_id, 'refund', v_amount, v_percent)
     and not billing.needs_checker(p_tenant_id, v_amount)
     and not (v_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id)) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent,
      audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(), v_payload)
    returning id into v_approval;
    v_id := billing.insert_refund(
      p_tenant_id, p_payment_id, v_amount, v_mode, nullif(p_body ->> 'reference', ''), v_approval, gen_random_uuid(), v_session);
    return billing.receipt_json(v_id);
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), 'pending', v_payload)
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending');
end;
$$;

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
  if billing.within_limit(p_tenant_id, 'discount', v_amount, v_percent)
     and not billing.needs_checker(p_tenant_id, v_amount) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'discount', 'bill', p_bill_id, v_amount, v_percent, audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(),
      jsonb_build_object('billId', p_bill_id, 'billLineId', v_line, 'kind', v_kind, 'value', v_value, 'reasonCode', v_reason))
    returning id into v_approval;
    insert into billing.discount (tenant_id, bill_id, bill_line_id, kind, value, reason_code, approval_id)
    values (p_tenant_id, p_bill_id, v_line, v_kind, v_value, v_reason, v_approval);
    return billing.bill_json(p_bill_id) || jsonb_build_object('approvalId', v_approval, 'approvalStatus', 'approved');
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
  -- Pending means a second person was required. Another role, or a lower threshold, does not let the maker approve it.
  if v_status = 'approved'
     and v_req.requested_by is not distinct from audit.session_actor_id() then
    raise exception 'You requested this, so someone else must approve it.' using errcode = '42501';
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
      v_req.payload ->> 'mode', nullif(v_req.payload ->> 'reference', ''), p_approval_id, gen_random_uuid(),
      nullif(v_req.payload ->> 'counterSessionId', '')::uuid);
    return billing.receipt_json(v_refund);
  end if;
  return jsonb_build_object('approvalId', p_approval_id, 'status', v_status, 'approverId', audit.session_actor_id());
end;
$$;

-- Unpaid draft: cancel it. Paid cancel/no-show: one pending refund for the configured share.
-- Idempotent on (payment, appointment id in the approval payload).
create or replace function billing.settle_closed_visit(p_tenant_id uuid, p_appointment_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ref record;
  v_account uuid;
  v_bill uuid;
  v_status text;
  v_pct integer;
  v_payment uuid;
  v_remaining bigint;
  v_amount bigint;
begin
  select * into v_ref from appointment.appointment_billing_ref_v1(p_tenant_id, p_appointment_id);
  if v_ref.patient_id is null then
    raise exception 'appointment not found' using errcode = 'P0002';
  end if;
  if v_ref.status not in ('cancelled', 'no_show') then
    return jsonb_build_object('status', 'skipped');
  end if;
  select a.id into v_account from billing.billing_account a
  where a.tenant_id = p_tenant_id and a.source_ref_type = 'appointment' and a.source_ref_id = p_appointment_id and not a.is_deleted;
  if v_account is null then
    return jsonb_build_object('status', 'unpaid');
  end if;
  select b.id, b.status into v_bill, v_status from billing.bill b
  where b.account_id = v_account and b.bill_kind = 'final' and not b.is_deleted
  order by b.created_on limit 1;
  if v_status = 'cancelled_draft' then
    return jsonb_build_object('status', 'cancelled_draft', 'billId', v_bill);
  end if;
  if v_status = 'draft' and billing.allocated_paise(v_bill) = 0 then
    perform billing.cancel_draft(p_tenant_id, v_bill);
    return jsonb_build_object('status', 'cancelled_draft', 'billId', v_bill);
  end if;
  v_pct := billing.visit_refund_pct(p_tenant_id, v_ref.status);
  if v_pct = 0 then
    return jsonb_build_object('status', 'policy', 'billId', v_bill);
  end if;
  select p.id,
         p.amount_paise - coalesce((
           select sum(r.amount_paise) from billing.payment r
           where r.refund_of_payment_id = p.id and not r.is_deleted), 0)
  into v_payment, v_remaining
  from billing.payment p
  where p.account_id = v_account and p.kind <> 'refund' and not p.is_deleted
    and exists (
      select 1 from billing.allocation al
      where al.payment_id = p.id and not al.is_deleted
      group by al.bill_id
      having sum(al.amount_paise) > 0)
  order by p.received_at desc
  limit 1;
  if v_payment is null or v_remaining is null or v_remaining <= 0 then
    return jsonb_build_object('status', 'nothing_to_refund', 'billId', v_bill);
  end if;
  v_amount := round(v_remaining * v_pct / 10000.0)::bigint;
  if v_amount <= 0 then
    return jsonb_build_object('status', 'policy', 'billId', v_bill);
  end if;
  if exists (
    select 1 from billing.approval_request r
    where r.tenant_id = p_tenant_id and r.action = 'refund' and r.subject_id = v_payment and not r.is_deleted
      and r.status in ('pending', 'approved')
      and r.payload ->> 'appointmentId' = p_appointment_id::text
  ) then
    return jsonb_build_object('status', 'duplicate', 'billId', v_bill, 'paymentId', v_payment);
  end if;
  return billing.request_refund(p_tenant_id, v_payment, jsonb_build_object(
    'amountPaise', v_amount, 'appointmentId', p_appointment_id));
end;
$$;

-- Runs as the bill owner so bypass_acl is true: reception can cancel without billing.refund,
-- and the refund request is still recorded. Errors propagate; the visit change rolls back with them.
create or replace function appointment.apply_billing_on_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status and not new.is_deleted then
    if new.status = 'checked_in' then
      perform billing.ensure_draft(new.tenant_id, new.id);
    elsif new.status in ('cancelled', 'no_show') then
      perform billing.settle_closed_visit(new.tenant_id, new.id);
    end if;
  end if;
  return null;
end;
$$;
comment on function appointment.apply_billing_on_status() is
  'After an appointment status change: open the consult draft on check-in, and settle a cancel or no-show.';
revoke all on function appointment.apply_billing_on_status() from public, anon, authenticated;
grant execute on function appointment.apply_billing_on_status() to hms_svc_scheduling, service_role;

do $$
declare
  v_owner name;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
  from pg_catalog.pg_class c where c.oid = 'billing.bill'::regclass;
  execute format('alter function appointment.apply_billing_on_status() owner to %I', v_owner);
  execute format('grant execute on function appointment.apply_billing_on_status() to %I', v_owner);
end
$$;

create trigger appointments_billing
  after update of status on appointment.appointments
  for each row execute function appointment.apply_billing_on_status();

revoke all on all functions in schema billing from public, anon, authenticated;
grant execute on all functions in schema billing to hms_svc_billing;
grant execute on function billing.public_link(text) to anon;
grant execute on function billing.apply_webhook(text, jsonb) to service_role;

-- 20261025240100 revokes service_role from the merge mover. This file sorts after it,
-- and the blanket grant above must not hand that function back to service_role.
-- Bills, refunds and credit notes have no patient_id; they follow billing_account.
revoke all on function billing.repoint_patient_for_merge(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function billing.repoint_patient_for_merge(uuid, uuid, uuid) to hms_svc_billing;
