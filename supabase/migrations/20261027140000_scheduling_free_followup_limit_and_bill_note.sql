-- Free follow-ups: a per-visit-type limit on free/reduced follow-ups per episode (default 1),
-- the entitlement the follow-up used, and a bill note ("Free follow-up (within N days of <date>)").
-- The .NET booking path computes the fee and note in the branch time zone and snapshots both here.
-- Other bill lines (labs, procedures, ...) are untouched and charged normally.
-- cross-schema: approved (billing.ensure_draft reads the published appointment.appointment_consultation_fee_v2;
-- no appointment table read from billing. v1 is kept for existing callers.)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- Scheduling ---------------------------------------------------------------
alter table appointment.visit_types
  add column follow_up_free_limit smallint default 1,
  add constraint visit_types_free_limit check (follow_up_free_limit is null or follow_up_free_limit between 0 and 50);
comment on column appointment.visit_types.follow_up_free_limit is
  'How many follow-ups inside the window get follow_up_fee_paise (free or reduced). Default 1 per episode. Null = no limit. Later follow-ups pay the normal fee.';

alter table appointment.appointments
  add column granted_follow_up_limit smallint,
  add column follow_up_entitlement_id uuid,
  add column consultation_fee_note text,
  add constraint appointments_granted_free_limit check (granted_follow_up_limit is null or granted_follow_up_limit between 0 and 50),
  add constraint appointments_fee_note_len check (consultation_fee_note is null or char_length(consultation_fee_note) <= 200),
  add constraint appointments_entitlement_not_self check (follow_up_entitlement_id is distinct from id),
  add constraint appointments_entitlement_same_tenant
    foreign key (tenant_id, follow_up_entitlement_id) references appointment.appointments (tenant_id, id);
create index appointments_entitlement_idx on appointment.appointments (tenant_id, follow_up_entitlement_id)
  where follow_up_entitlement_id is not null;
comment on column appointment.appointments.granted_follow_up_limit is
  'Snapshot of follow_up_free_limit when this visit opened a window. Null = no limit.';
comment on column appointment.appointments.follow_up_entitlement_id is
  'The earlier visit whose window gave this follow-up its free or reduced fee. Counted (excluding cancelled and no-show) against that visit''s granted_follow_up_limit.';
comment on column appointment.appointments.consultation_fee_note is
  'Bill note for the snapshotted fee, e.g. "Free follow-up (within 7 days of 1 Oct 2026)". Copied to the CONSULT line on check-in.';

-- Existing windows keep the spec default of one free follow-up.
update appointment.appointments set granted_follow_up_limit = 1
where granted_follow_up_days is not null and granted_follow_up_limit is null;

grant insert (follow_up_free_limit) on appointment.visit_types to authenticated, hms_svc_scheduling;
grant update (follow_up_free_limit) on appointment.visit_types to authenticated, hms_svc_scheduling;
grant insert (granted_follow_up_limit, follow_up_entitlement_id, consultation_fee_note)
  on appointment.appointments to authenticated, hms_svc_scheduling;

-- cross-schema: approved (published v2 contract, docs/contracts/db.md; consumer: billing)
create or replace function appointment.appointment_consultation_fee_v2(p_tenant_id uuid, p_appointment_id uuid)
returns table (visit_type_id uuid, visit_type_code text, consultation_fee_paise bigint, consultation_fee_note text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select a.visit_type_id, vt.code, a.consultation_fee_paise, a.consultation_fee_note
  from appointment.appointments a
  left join appointment.visit_types vt
    on vt.tenant_id = a.tenant_id and vt.id = a.visit_type_id and not vt.is_deleted
  where a.tenant_id = p_tenant_id
    and a.id = p_appointment_id
    and not a.is_deleted;
end;
$$;
revoke all on function appointment.appointment_consultation_fee_v2(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.appointment_consultation_fee_v2(uuid, uuid) to service_role, hms_svc_billing;
comment on function appointment.appointment_consultation_fee_v2(uuid, uuid) is
  'v2 (published by scheduling): v1 plus consultation_fee_note, the bill note for a free or reduced follow-up. Empty when the appointment is missing.';

-- Billing ------------------------------------------------------------------
alter table billing.bill_line
  add column note text,
  add constraint bill_line_note_len check (note is null or char_length(note) <= 200);
comment on column billing.bill_line.note is
  'Optional printed note under the line, e.g. "Free follow-up (within 7 days of 1 Oct 2026)". Set by ensure_draft only.';

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
  v_fee bigint;
  v_note text;
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
      -- Null means this booking did not choose a visit type: keep the catalog price.
      -- 0 is a free follow-up and must replace the catalog price.
      -- The note ("Free follow-up (within N days of <date>)") is printed under the line.
      select f.consultation_fee_paise, f.consultation_fee_note into v_fee, v_note
      from appointment.appointment_consultation_fee_v2(p_tenant_id, p_appointment_id) f;
      if v_fee is not null then
        update billing.bill_line
        set unit_price_paise = v_fee, note = v_note
        where bill_id = v_bill
          and not is_deleted
          and line_no = (select max(line_no) from billing.bill_line where bill_id = v_bill and not is_deleted);
      end if;
    end if;
  end if;
  return billing.bill_json(v_bill);
end;
$$;

comment on function billing.ensure_draft(uuid, uuid) is
  'Open the consult draft for a checked-in appointment. The first CONSULT line uses the price catalog, then a non-null appointment.appointment_consultation_fee_v2 fee (including 0) and its note replace that line price. A later call does not rewrite an existing line.';

-- Same as 20261025240200 plus the line note.
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
      'note', l.note,
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
