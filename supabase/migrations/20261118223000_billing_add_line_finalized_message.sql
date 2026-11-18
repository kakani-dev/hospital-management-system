-- #316: adding a line to a finalized bill tells staff the bill is immutable
-- and to issue a credit note (BIL-007). A cancelled draft still uses the
-- existing "only a draft bill accepts lines" message.
-- cross-schema: approved (this only replaces billing.add_line; the body still reads
-- the published identity.branch_local_date_v1 and appointment.appointment_consultation_fee_v2
-- contracts, same as 20261027170000. No new cross-schema surface.)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.add_line(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_account billing.billing_account%rowtype;
  v_bill billing.bill%rowtype;
  v_item uuid;
  v_code text;
  v_price jsonb;
  v_line int;
  v_qty numeric := coalesce((p_body ->> 'quantity')::numeric, 1);
  v_prac uuid := nullif(p_body ->> 'practitionerId', '')::uuid;
  v_appt uuid;
  v_fee bigint;
  v_note text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_bill.status = 'finalized' then
    raise exception 'finalized bills are immutable; issue a credit note' using errcode = '55000';
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
  select si.code into v_code from billing.service_item si where si.id = v_item and si.tenant_id = p_tenant_id;
  if v_code is null then
    raise exception 'service item not found' using errcode = 'P0002';
  end if;
  if v_code = 'CONSULT' and v_prac is null then
    select c.practitioner_id, c.appointment_id into v_prac, v_appt
    from billing.consult_context(p_tenant_id, v_account.id) c;
    if v_appt is not null then
      select f.consultation_fee_paise, f.consultation_fee_note into v_fee, v_note
      from appointment.appointment_consultation_fee_v2(p_tenant_id, v_appt) f;
    end if;
  end if;
  v_price := billing.resolve_price(
    p_tenant_id, v_account.branch_id, v_item, v_prac,
    identity.branch_local_date_v1(v_account.branch_id, pg_catalog.now()));
  select coalesce(max(line_no), 0) + 1 into v_line from billing.bill_line where bill_id = p_bill_id;
  insert into billing.bill_line (
    tenant_id, bill_id, line_no, service_item_id, price_list_item_id, practitioner_id,
    quantity, unit_price_paise, tax_rate_bp, note)
  values (
    p_tenant_id, p_bill_id, v_line, v_item, (v_price ->> 'priceListItemId')::uuid, v_prac,
    v_qty, coalesce(v_fee, (v_price ->> 'unitPricePaise')::bigint), (v_price ->> 'taxRateBp')::integer,
    case when v_fee is not null then v_note end);
  return billing.bill_json(p_bill_id);
end;
$$;
