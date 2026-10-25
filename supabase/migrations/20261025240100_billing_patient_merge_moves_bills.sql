-- cross-schema: approved (patient.merge_patients_apply calls billing.repoint_patient_for_merge
-- in the same transaction. The outbox consumer calls the same function.)
-- Merge moves bills with the chart. billing.repoint_patient still requires billing.bill, so a
-- tenant_admin merge (or a dispatcher with no user JWT) would leave the accounts behind.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.repoint_patient_for_merge(p_tenant_id uuid, p_from uuid, p_to uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or p_from is null or p_to is null or p_from = p_to then
    return;
  end if;

  update billing.billing_account
     set patient_id = p_to
   where tenant_id = p_tenant_id and patient_id = p_from and not is_deleted;

  if exists (
    select 1 from billing.wallet w
     where w.tenant_id = p_tenant_id and w.holder_patient_id = p_to and not w.is_deleted) then
    update billing.wallet
       set is_deleted = true
     where tenant_id = p_tenant_id and holder_patient_id = p_from and not is_deleted;
  else
    update billing.wallet
       set holder_patient_id = p_to
     where tenant_id = p_tenant_id and holder_patient_id = p_from and not is_deleted;
  end if;

  -- wallet_member is unique on (tenant_id, patient_id) including soft-deleted rows.
  if exists (
    select 1 from billing.wallet_member m
     where m.tenant_id = p_tenant_id and m.patient_id = p_to and not m.is_deleted) then
    update billing.wallet_member
       set is_deleted = true
     where tenant_id = p_tenant_id and patient_id = p_from and not is_deleted;
  else
    update billing.wallet_member
       set patient_id = p_to
     where tenant_id = p_tenant_id and patient_id = p_from and not is_deleted;
  end if;

  update billing.cost_estimate
     set patient_id = p_to
   where tenant_id = p_tenant_id and patient_id = p_from and not is_deleted;
end;
$$;
revoke all on function billing.repoint_patient_for_merge(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function billing.repoint_patient_for_merge(uuid, uuid, uuid) to hms_svc_billing;
comment on function billing.repoint_patient_for_merge(uuid, uuid, uuid) is
  'Owner-only (plus the billing service). Moves accounts, wallets and estimates onto the survivor. No permission check: patient.merge_patients_apply is the gate.';

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
    perform billing.repoint_patient_for_merge(v_tenant, (p_payload ->> 'duplicate_patient_id')::uuid, (p_payload ->> 'survivor_patient_id')::uuid);
  end if;
  return jsonb_build_object('duplicate', false);
end;
$$;

-- Same body as 20261022130200, plus the billing move inside the merge transaction.
create or replace function patient.merge_patients_apply(
  p_survivor_id uuid, p_duplicate_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sur record;
  v_dup record;
  v_sur_found boolean;
  v_dup_found boolean;
  v_email text;
  v_abha text;
  v_dob date;
  v_sex text;
  v_reason text;
  v_phone record;
  v_primary boolean;
  v_wa boolean;
begin
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null then
    raise exception 'reason is required' using errcode = '22023';
  end if;
  if length(p_reason) > 500 or length(v_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;
  if p_survivor_id is null or p_duplicate_id is null then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if p_survivor_id = p_duplicate_id then
    raise exception 'a chart cannot be merged into itself' using errcode = '22023';
  end if;

  if p_survivor_id < p_duplicate_id then
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_sur from patient.patients p where p.id = p_survivor_id for update;
    v_sur_found := found;
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_dup from patient.patients p where p.id = p_duplicate_id for update;
    v_dup_found := found;
  else
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_dup from patient.patients p where p.id = p_duplicate_id for update;
    v_dup_found := found;
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_sur from patient.patients p where p.id = p_survivor_id for update;
    v_sur_found := found;
  end if;

  if not v_sur_found or not v_dup_found or v_sur.tenant_id is distinct from v_dup.tenant_id then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if v_dup.merged_into_patient_id = p_survivor_id and v_dup.deleted_at is not null then
    raise notice 'patient.merge: % already merged into %', v_dup.mrn, v_sur.mrn;
    return;
  end if;
  if v_dup.merged_into_patient_id is not null then
    raise exception 'patient is already merged into another chart' using errcode = '22023';
  end if;
  if v_sur.deleted_at is not null or v_sur.merged_into_patient_id is not null then
    raise exception 'survivor is not a live chart' using errcode = '22023';
  end if;

  v_email := nullif(btrim(v_dup.email), '');
  v_abha := v_dup.abha_number;
  v_dob := v_dup.date_of_birth;
  v_sex := v_dup.sex;

  perform set_config('patient.merge', 'on', true);
  begin
    perform appointment.reassign_patient_for_merge(v_sur.tenant_id, p_duplicate_id, p_survivor_id);
    perform billing.repoint_patient_for_merge(v_sur.tenant_id, p_duplicate_id, p_survivor_id);

    for v_phone in
      select id, phone_e164, is_primary, is_whatsapp
        from patient.patient_phones
       where patient_id = p_duplicate_id and not is_deleted
       order by id
       for update
    loop
      if exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and not s.is_deleted
           and patient.normalize_phone(s.phone_e164) is not null
           and patient.normalize_phone(s.phone_e164) = patient.normalize_phone(v_phone.phone_e164)) then
        update patient.patient_phones set is_deleted = true where id = v_phone.id;
        continue;
      end if;
      v_primary := v_phone.is_primary;
      v_wa := v_phone.is_whatsapp;
      if v_primary and exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and s.is_primary and not s.is_deleted) then
        v_primary := false;
      end if;
      if v_wa and exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and s.is_whatsapp and not s.is_deleted) then
        v_wa := false;
      end if;
      if not v_primary and not v_wa then
        update patient.patient_phones set is_deleted = true where id = v_phone.id;
      else
        update patient.patient_phones
           set patient_id = p_survivor_id, is_primary = v_primary, is_whatsapp = v_wa
         where id = v_phone.id;
      end if;
    end loop;

    update patient.patients
       set deleted_at = now(),
           deleted_by = coalesce(auth.uid(), audit.system_actor()),
           deletion_reason = v_reason,
           merged_into_patient_id = p_survivor_id,
           merged_at = now(),
           merged_by = coalesce(auth.uid(), audit.system_actor())
     where id = p_duplicate_id;

    update patient.patients s
       set email = case when nullif(btrim(s.email), '') is null then v_email else s.email end,
           abha_number = case when s.abha_number is null then v_abha else s.abha_number end,
           date_of_birth = case when s.date_of_birth is null then v_dob else s.date_of_birth end,
           sex = case when s.sex = 'unknown' and v_sex is distinct from 'unknown' then v_sex else s.sex end,
           phone = case when nullif(btrim(s.phone), '') is null then (
             select live.phone_e164 from patient.patient_phones live
              where live.patient_id = s.id and live.is_primary and not live.is_deleted
              limit 1) else s.phone end
     where s.id = p_survivor_id;

    perform messaging.enqueue(v_sur.tenant_id, 'patient', p_survivor_id, 'patient.merged', jsonb_build_object(
      'survivor_patient_id', p_survivor_id,
      'duplicate_patient_id', p_duplicate_id,
      'tenant_id', v_sur.tenant_id));

    perform set_config('patient.merge', '', true);
  exception when others then
    perform set_config('patient.merge', '', true);
    raise;
  end;
end;
$$;
revoke all on function patient.merge_patients_apply(uuid, uuid, text) from public, anon, authenticated, service_role;
comment on function patient.merge_patients_apply(uuid, uuid, text) is
  'Owner-only merge. Repoints visits, queue, phones and billing, soft-deletes the duplicate, fills blank survivor fields, writes audit (via the row trigger) and a patient.merged outbox event.';
