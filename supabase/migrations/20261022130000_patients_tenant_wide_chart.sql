-- cross-schema: approved (patient.soft_delete_patient keeps calling appointment.patient_has_open_visits_v1)
-- Patients are shared across every branch of a hospital. The registered branch is metadata.
-- Role permissions still apply (patients.edit / patients.delete). Another hospital stays invisible (P0002 / 0 rows).
-- Duplicate charts: email, phone and ABHA are unique among live patients of the hospital.
-- The same name warns (including when a date of birth is missing); a stored reason is the API's confirmation.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------- patients ----
drop policy patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (not is_deleted
         and identity.has_tenant_permission(tenant_id, 'patients.edit'))
  with check (identity.has_tenant_permission(tenant_id, 'patients.edit'));

comment on policy patients_update_registry_writers on patient.patients is
  'patients.edit anywhere in the hospital. registered_branch_id is metadata (same-tenant FK).';

alter table patient.patients
  add column duplicate_override_reason text,
  add constraint patients_duplicate_override_reason_len
    check (duplicate_override_reason is null or char_length(duplicate_override_reason) <= 500);
grant insert (duplicate_override_reason), update (duplicate_override_reason) on patient.patients to authenticated;
comment on column patient.patients.duplicate_override_reason is
  'Why a same-name chart was registered anyway. Required by the API when the name matches a live patient (date of birth may be blank). Email, phone and ABHA are never overridable.';

-- Live email / phone / ABHA unique indexes are created in 20261022130300, after
-- 20261022130200 merges existing duplicate charts. Creating them in this file would fail on those rows.

create or replace function patient.reject_shared_phone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_deleted then
    return new;
  end if;
  if exists (
    select 1 from patient.patient_phones ph
     where ph.tenant_id = new.tenant_id
       and not ph.is_deleted
       and ph.patient_id <> new.patient_id
       and ph.id is distinct from new.id
       and patient.normalize_phone(ph.phone_e164) is not null
       and patient.normalize_phone(ph.phone_e164) = patient.normalize_phone(new.phone_e164)) then
    raise exception 'duplicate_phone: another patient in this hospital already has this phone number'
      using errcode = '23505';
  end if;
  return new;
end;
$$;
revoke all on function patient.reject_shared_phone() from public, anon, authenticated;
create trigger patient_phones_shared_number
  before insert or update of phone_e164, is_deleted, patient_id on patient.patient_phones
  for each row execute function patient.reject_shared_phone();

-- 22023 invalid input, P0002 unknown / foreign / deleted patient, 42501 no patients.edit in the hospital.
create or replace function patient.set_patient_phones(
  p_patient_id uuid, p_phone text, p_whatsapp_same boolean, p_whatsapp text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
  v_wa text;
begin
  select p.id, p.tenant_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;
  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_permission(v_p.tenant_id, 'patients.edit') then
    raise exception 'not permitted to edit this patient' using errcode = '42501';
  end if;
  if p_phone is not null and p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'phone must be E.164' using errcode = '22023';
  end if;
  if p_whatsapp is not null and p_whatsapp !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'whatsapp must be E.164' using errcode = '22023';
  end if;
  if coalesce(p_whatsapp_same, false) and p_phone is null then
    raise exception 'whatsapp same as phone needs a phone number' using errcode = '22023';
  end if;

  v_wa := case when coalesce(p_whatsapp_same, false) then p_phone else p_whatsapp end;

  update patient.patient_phones
     set is_deleted = true
   where patient_id = v_p.id and not is_deleted
     and (is_primary is distinct from (phone_e164 is not distinct from p_phone)
          or is_whatsapp is distinct from (phone_e164 is not distinct from v_wa));
  if p_phone is not null and not exists (
      select 1 from patient.patient_phones where patient_id = v_p.id and not is_deleted and phone_e164 = p_phone) then
    insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
    values (v_p.tenant_id, v_p.id, p_phone, true, coalesce(p_phone = v_wa, false));
  end if;
  if v_wa is not null and v_wa is distinct from p_phone and not exists (
      select 1 from patient.patient_phones where patient_id = v_p.id and not is_deleted and phone_e164 = v_wa) then
    insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
    values (v_p.tenant_id, v_p.id, v_wa, false, true);
  end if;

  update patient.patients set phone = p_phone where id = v_p.id and phone is distinct from p_phone;
end;
$$;

-- patients.delete anywhere in the hospital. Open visits still block the delete (55000).
create or replace function patient.soft_delete_patient(p_patient_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  if p_reason is not null and length(p_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;

  select p.id, p.tenant_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_permission(v_p.tenant_id, 'patients.delete') then
    raise exception 'not permitted to delete this patient' using errcode = '42501';
  end if;

  if appointment.patient_has_open_visits_v1(v_p.tenant_id, v_p.id) then
    raise exception 'patient has open appointments or queue entries; cancel them first' using errcode = '55000';
  end if;

  update patient.patients
     set deleted_at = now(),
         deleted_by = auth.uid(),
         deletion_reason = nullif(btrim(p_reason), '')
   where id = v_p.id;
end;
$$;

-- Extra arguments (email, ABHA) are optional so existing 6-arg calls keep working.
drop function if exists patient.find_duplicate_patients(uuid, text, text, date, text, uuid);
create function patient.find_duplicate_patients(
  p_tenant_id uuid,
  p_first_name text,
  p_last_name text,
  p_date_of_birth date,
  p_phone text,
  p_exclude_id uuid default null,
  p_email text default null,
  p_abha text default null)
returns table (
  patient_id uuid,
  mrn text,
  first_name text,
  last_name text,
  date_of_birth date,
  phone text,
  registered_branch_id uuid,
  match_reasons text[])
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']) then
    raise exception 'not permitted to search patients' using errcode = '42501';
  end if;

  return query
  select p.id, p.mrn, p.first_name, p.last_name, p.date_of_birth,
         (select ph.phone_e164 from patient.patient_phones ph
           where ph.patient_id = p.id and ph.is_primary and not ph.is_deleted),
         p.registered_branch_id,
         array_remove(array[
           case when m.by_name_dob then 'name_dob' end,
           case when m.by_name then 'name' end,
           case when m.by_phone then 'phone' end,
           case when m.by_email then 'email' end,
           case when m.by_abha then 'abha' end], null)
  from patient.patients p
  cross join lateral (
    select
      (btrim(coalesce(p_first_name, '')) <> '' and btrim(coalesce(p_last_name, '')) <> ''
        and lower(btrim(p.last_name)) = lower(btrim(p_last_name))
        and lower(btrim(p.first_name)) = lower(btrim(p_first_name))) as names,
      (nullif(btrim(p_email), '') is not null and nullif(btrim(p.email), '') is not null
        and lower(btrim(p.email)) = lower(btrim(p_email))) as by_email,
      coalesce(patient.normalize_phone(p_phone) is not null and exists (
        select 1 from patient.patient_phones ph
        where ph.tenant_id = p_tenant_id and ph.patient_id = p.id and not ph.is_deleted
          and patient.normalize_phone(ph.phone_e164) = patient.normalize_phone(p_phone)), false) as by_phone,
      (length(regexp_replace(coalesce(p_abha, ''), '[^0-9]', '', 'g')) = 14
        and regexp_replace(coalesce(p.abha_number, ''), '[^0-9]', '', 'g')
            = regexp_replace(p_abha, '[^0-9]', '', 'g')) as by_abha
  ) idn
  cross join lateral (
    select
      idn.names and p_date_of_birth is not null and p.date_of_birth is not null
        and p.date_of_birth = p_date_of_birth as by_name_dob,
      idn.names and (p_date_of_birth is null or p.date_of_birth is null) as by_name,
      idn.by_phone,
      idn.by_email,
      idn.by_abha
  ) m
  where p.tenant_id = p_tenant_id
    and not p.is_deleted
    and (p_exclude_id is null or p.id <> p_exclude_id)
    and (m.by_name or m.by_name_dob or m.by_phone or m.by_email or m.by_abha)
  order by (m.by_email or m.by_phone or m.by_abha) desc, (m.by_name_dob or m.by_name) desc, p.last_name, p.first_name, p.mrn
  limit 20;
end;
$$;
revoke all on function patient.find_duplicate_patients(uuid, text, text, date, text, uuid, text, text) from public, anon;
grant execute on function patient.find_duplicate_patients(uuid, text, text, date, text, uuid, text, text) to authenticated, service_role;
comment on function patient.find_duplicate_patients(uuid, text, text, date, text, uuid, text, text) is
  'Live patients in this hospital matching email, phone (last 10 digits), ABHA, or exact name. '
  'name_dob when both dates are present and equal; name when the names match and either date is blank. '
  'Different dates of birth are not a name match. Email, phone and ABHA are hard conflicts; name is a warning.';
