-- #190: registration fields that match Indian OPD practice.
-- * Single-name patients: last_name may be blank (stored ''), first name is still required.
-- * Age-only registration: date_of_birth can be estimated from an age; dob_estimated flags it.
-- * No mobile: the reason is kept in no_phone_reason.
-- What a NEW registration must provide (sex chosen, DOB or age, mobile or reason) is enforced by the
-- patients API on create only; existing charts stay valid, so these are not table constraints.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table patient.patients drop constraint if exists patients_names_not_blank;
alter table patient.patients add constraint patients_first_name_not_blank check (length(btrim(first_name)) > 0);
alter table patient.patients add column if not exists dob_estimated boolean not null default false;
alter table patient.patients add column if not exists no_phone_reason text;
alter table patient.patients add constraint patients_no_phone_reason_len
  check (no_phone_reason is null or char_length(no_phone_reason) between 3 and 200);
alter table patient.patients add constraint patients_dob_estimated_has_dob
  check (not dob_estimated or date_of_birth is not null);

-- Same column grants as the other writable patient columns.
grant select (dob_estimated, no_phone_reason), insert (dob_estimated, no_phone_reason), update (dob_estimated, no_phone_reason)
  on patient.patients to hms_svc_patients, authenticated;

-- Duplicate check: two single-name patients with the same first name now match on name
-- (before, a blank last name switched name matching off).
CREATE OR REPLACE FUNCTION patient.find_duplicate_patients(p_tenant_id uuid, p_first_name text, p_last_name text, p_date_of_birth date, p_phone text, p_exclude_id uuid DEFAULT NULL::uuid, p_email text DEFAULT NULL::text, p_abha text DEFAULT NULL::text)
 RETURNS TABLE(patient_id uuid, mrn text, first_name text, last_name text, date_of_birth date, phone text, registered_branch_id uuid, match_reasons text[])
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
      (btrim(coalesce(p_first_name, '')) <> ''
        and lower(btrim(p.last_name)) = lower(btrim(coalesce(p_last_name, '')))
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
$function$

;
