-- #165: a CONSULT line added without a doctor takes the doctor (and visit-type fee) of the
--       patient's visit on the server, never from the client.
-- #169: a walk-in token opens the consult draft the same way a booked check-in does.
-- cross-schema: approved (published v1 scheduling contracts below; consumer: billing.
-- Billing reads queue data only through these functions.)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- cross-schema: approved (published by scheduling; consumer: billing)
create or replace function appointment.queue_entry_billing_ref_v1(p_tenant_id uuid, p_queue_entry_id uuid)
returns table (patient_id uuid, branch_id uuid, practitioner_id uuid, appointment_id uuid, status text, queue_date date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select q.patient_id, q.branch_id, q.practitioner_id, q.appointment_id, q.status, q.queue_date
  from appointment.queue_entries q
  where q.tenant_id = p_tenant_id and q.id = p_queue_entry_id and not q.is_deleted;
end;
$$;
revoke all on function appointment.queue_entry_billing_ref_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.queue_entry_billing_ref_v1(uuid, uuid) to service_role, hms_svc_billing;
comment on function appointment.queue_entry_billing_ref_v1(uuid, uuid) is
  'v1 (published by scheduling): patient, branch, doctor, appointment (null for a walk-in), status and day of one queue entry. No names. Empty when missing.';

-- cross-schema: approved (published by scheduling; consumer: billing)
create or replace function appointment.patient_queue_today_v1(p_tenant_id uuid, p_branch_id uuid, p_patient_id uuid)
returns table (queue_entry_id uuid, appointment_id uuid, practitioner_id uuid, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select q.id, q.appointment_id, q.practitioner_id, q.status
  from appointment.queue_entries q
  where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id and q.patient_id = p_patient_id
    and q.queue_date = identity.branch_local_date_v1(p_branch_id)
    and q.status <> 'cancelled' and not q.is_deleted
  order by q.token_no desc
  limit 1;
end;
$$;
revoke all on function appointment.patient_queue_today_v1(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.patient_queue_today_v1(uuid, uuid, uuid) to service_role, hms_svc_billing;
comment on function appointment.patient_queue_today_v1(uuid, uuid, uuid) is
  'v1 (published by scheduling): the patient''s latest non-cancelled queue entry today at the branch (branch-local day). Empty when none.';

alter table billing.billing_account drop constraint billing_account_source;
alter table billing.billing_account add constraint billing_account_source
  check (source_ref_type in ('appointment', 'admission', 'queue_entry', 'none'));

create or replace function billing.consult_context(p_tenant_id uuid, p_account_id uuid)
returns table (practitioner_id uuid, appointment_id uuid)
language plpgsql stable set search_path = ''
as $$
declare
  v_acc billing.billing_account%rowtype;
  v_prac uuid;
  v_appt uuid;
begin
  select * into v_acc from billing.billing_account a where a.id = p_account_id and a.tenant_id = p_tenant_id;
  if v_acc.id is null then
    return;
  end if;
  if v_acc.source_ref_type = 'appointment' then
    v_appt := v_acc.source_ref_id;
    select r.practitioner_id into v_prac from appointment.appointment_billing_ref_v1(p_tenant_id, v_appt) r;
  elsif v_acc.source_ref_type = 'queue_entry' then
    select r.practitioner_id, r.appointment_id into v_prac, v_appt
    from appointment.queue_entry_billing_ref_v1(p_tenant_id, v_acc.source_ref_id) r;
  else
    select r.practitioner_id, r.appointment_id into v_prac, v_appt
    from appointment.patient_queue_today_v1(p_tenant_id, v_acc.branch_id, v_acc.patient_id) r;
  end if;
  if v_prac is null and v_appt is not null then
    select r.practitioner_id into v_prac from appointment.appointment_billing_ref_v1(p_tenant_id, v_appt) r;
  end if;
  practitioner_id := v_prac;
  appointment_id := v_appt;
  return next;
end;
$$;

-- Same as 20261023120500 plus: a CONSULT line with no practitionerId takes the visit's doctor
-- and, for a booking with a snapshotted fee, that fee and its note.
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

create or replace function billing.ensure_walk_in_draft(p_tenant_id uuid, p_queue_entry_id uuid)
returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_ref record;
  v_account uuid;
  v_bill uuid;
  v_status text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_ref from appointment.queue_entry_billing_ref_v1(p_tenant_id, p_queue_entry_id);
  if v_ref.patient_id is null then
    raise exception 'queue entry not found' using errcode = 'P0002';
  end if;
  if v_ref.appointment_id is not null then
    return billing.ensure_draft(p_tenant_id, v_ref.appointment_id);
  end if;
  perform billing.assert_branch(p_tenant_id, v_ref.branch_id);
  if v_ref.status = 'cancelled' then
    raise exception 'the walk-in token is cancelled' using errcode = '55000';
  end if;
  perform billing.ensure_defaults(p_tenant_id);
  select a.id into v_account from billing.billing_account a
  where a.tenant_id = p_tenant_id and a.source_ref_type = 'queue_entry' and a.source_ref_id = p_queue_entry_id and not a.is_deleted;
  if v_account is null then
    insert into billing.billing_account (tenant_id, patient_id, branch_id, account_type, source_ref_type, source_ref_id)
    values (p_tenant_id, v_ref.patient_id, v_ref.branch_id, 'op_visit', 'queue_entry', p_queue_entry_id)
    returning id into v_account;
  end if;
  select b.id, b.status into v_bill, v_status from billing.bill b
  where b.account_id = v_account and b.bill_kind = 'final' and not b.is_deleted
  order by b.created_on limit 1;
  if v_bill is null then
    insert into billing.bill (tenant_id, account_id, bill_kind)
    values (p_tenant_id, v_account, 'final')
    returning id into v_bill;
  end if;
  if (v_status is null or v_status = 'draft')
     and not exists (select 1 from billing.bill_line l where l.bill_id = v_bill and not l.is_deleted) then
    perform billing.add_line(p_tenant_id, v_bill, jsonb_build_object('code', 'CONSULT', 'practitionerId', v_ref.practitioner_id));
  end if;
  return billing.bill_json(v_bill);
end;
$$;
comment on function billing.ensure_walk_in_draft(uuid, uuid) is
  'Open the consult draft for a walk-in queue token (account source queue_entry). Idempotent: a later call returns the same bill and adds nothing.';

-- Same as 20261025240100 plus queue.token_issued for walk-ins.
create or replace function billing.consume_event(p_event_id uuid, p_event_type text, p_payload jsonb)
returns jsonb
language plpgsql set search_path = ''
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
  if p_event_type in ('queue.token_issued', 'queue.token_issued.v1') and v_appointment is null then
    return billing.ensure_walk_in_draft(v_tenant, (p_payload ->> 'queue_entry_id')::uuid) || jsonb_build_object('duplicate', false);
  end if;
  if p_event_type = 'patient.merged' then
    perform billing.repoint_patient_for_merge(v_tenant, (p_payload ->> 'duplicate_patient_id')::uuid, (p_payload ->> 'survivor_patient_id')::uuid);
  end if;
  return jsonb_build_object('duplicate', false);
end;
$$;

revoke all on function billing.consult_context(uuid, uuid) from public, anon, authenticated;
revoke all on function billing.ensure_walk_in_draft(uuid, uuid) from public, anon, authenticated;
grant execute on function billing.consult_context(uuid, uuid) to hms_svc_billing;
grant execute on function billing.ensure_walk_in_draft(uuid, uuid) to hms_svc_billing;
