-- Copy a snapshotted visit-type fee onto the check-in consult draft.
-- cross-schema: approved (billing.ensure_draft reads appointment.appointment_consultation_fee_v1.
-- No appointment table read. add_line still ignores any client price.)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

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
      select f.consultation_fee_paise into v_fee
      from appointment.appointment_consultation_fee_v1(p_tenant_id, p_appointment_id) f;
      if v_fee is not null then
        update billing.bill_line
        set unit_price_paise = v_fee
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
  'Open the consult draft for a checked-in appointment. The first CONSULT line uses the price catalog, then a non-null appointment.appointment_consultation_fee_v1 fee (including 0) replaces that line price. A later call does not rewrite an existing line.';

comment on function appointment.appointment_consultation_fee_v1(uuid, uuid) is
  'v1 (published by scheduling): visit type and the paise fee snapshotted at booking. Empty when the appointment is missing. Does not insert a bill line. billing.ensure_draft copies a non-null fee onto the check-in CONSULT line. A soft-deleted visit type leaves the code null and still returns the snapshotted fee.';

comment on column appointment.appointments.consultation_fee_paise is
  'Fee snapshot in paise at booking (visit type, branch override, and a free or reduced follow-up inside the prior visit window). On check-in, billing.ensure_draft copies a non-null value onto the CONSULT draft line. Null keeps the price-catalog price.';
