-- =============================================================================
-- Level 1 (patient): normalized patient phone numbers (3NF) with a WhatsApp flag.
--
--   patient.patient_phones  one row per (patient, E.164 number). A number is stored ONCE:
--       is_primary  the patient's phone (at most one live row per patient)
--       is_whatsapp the WhatsApp number (at most one live row per patient)
--     WhatsApp = phone   -> ONE row with is_primary AND is_whatsapp (the "same as phone" indicator)
--     a different number -> a second row with is_whatsapp only
--
--   Writes go ONLY through patient.set_patient_phones() (SECURITY DEFINER: soft delete / flag moves
--   need the owner, like soft_delete_patient). Clients get SELECT under RLS mirroring patients.
--
--   Expand phase: patient.patients.phone is DEPRECATED and kept as a mirror of the primary number
--   (written by set_patient_phones) for old readers. Duplicate check and phone search now read
--   patient_phones. TODO(contract): drop patient.patients.phone in a later migration once no reader
--   is left (patients service, published contracts, web).
--
--   Backfill: every live patients.phone that normalizes to E.164 (tenant default_country_code)
--   becomes a primary row and the mirror is rewritten to that E.164 value. A legacy value that
--   cannot be normalized is left untouched in the deprecated column (no row).
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ----------------------------------------------------------- normalizer ----
-- Mirrors the patients service (PhoneE164.Normalize). NULL = not a valid number.
--   +CC...  / 00CC...   international, kept
--   0XXXXXXXXXX         national with trunk 0 -> default code
--   CCXXXXXXXXXX        digits already starting with the default code (more than 10 digits) -> +
--   XXXXXXXXXX          national -> default code
create or replace function patient.to_e164(p_raw text, p_country_code text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := pg_catalog.regexp_replace(coalesce(p_raw, ''), '[[:space:]().-]', '', 'g');
  v_cc text := pg_catalog.ltrim(coalesce(p_country_code, '+91'), '+');
  v_out text;
begin
  if v = '' then
    return null;
  end if;
  if v ~ '^\+' then
    v_out := v;
  elsif v ~ '^00' then
    v_out := '+' || pg_catalog.substr(v, 3);
  elsif v !~ '^[0-9]+$' then
    return null;
  elsif pg_catalog.length(v) > 10 and pg_catalog.starts_with(v, v_cc) then
    v_out := '+' || v;
  else
    v_out := '+' || v_cc || pg_catalog.ltrim(v, '0');
  end if;
  if v_out ~ '^\+[1-9][0-9]{7,14}$' then
    return v_out;
  end if;
  return null;
end;
$$;
revoke all on function patient.to_e164(text, text) from public, anon;
grant execute on function patient.to_e164(text, text) to authenticated, service_role;

-- ------------------------------------------------------------------ table ----
create table patient.patient_phones (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  patient_id  uuid not null,
  phone_e164  text not null,
  is_primary  boolean not null default false,
  is_whatsapp boolean not null default false,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint patient_phones_e164_format check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  constraint patient_phones_has_purpose check (is_primary or is_whatsapp),
  -- tenant consistency: the row's tenant IS the patient's tenant
  constraint patient_phones_patient_same_tenant
    foreign key (tenant_id, patient_id) references patient.patients (tenant_id, id) on delete cascade
);
comment on table patient.patient_phones is
  'Patient phone numbers in E.164. One row per number; is_primary + is_whatsapp on one row = WhatsApp same as phone. Written only by patient.set_patient_phones().';

create unique index patient_phones_patient_number_key on patient.patient_phones (patient_id, phone_e164) where not is_deleted;
create unique index patient_phones_one_primary on patient.patient_phones (patient_id) where is_primary and not is_deleted;
create unique index patient_phones_one_whatsapp on patient.patient_phones (patient_id) where is_whatsapp and not is_deleted;
create index patient_phones_tenant_norm_idx on patient.patient_phones (tenant_id, patient.normalize_phone(phone_e164)) where not is_deleted;
create index patient_phones_tenant_patient_idx on patient.patient_phones (tenant_id, patient_id);

create trigger patient_phones_audit_columns before insert or update on patient.patient_phones
  for each row execute function audit.stamp_audit_columns();
create trigger patient_phones_tenant_immutable before update on patient.patient_phones
  for each row execute function audit.prevent_tenant_change();
create trigger patient_phones_audit_log after insert or update or delete on patient.patient_phones
  for each row execute function audit.log_row_change();

-- --------------------------------------------------------------------- RLS ----
-- Mirrors patients: registry read roles of the tenant; deleted phones (and phones of deleted
-- patients, hidden by the patients policy inside the EXISTS) only for tenant_admin.
alter table patient.patient_phones enable row level security;
create policy patient_phones_select_registry_roles on patient.patient_phones
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'])
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin']))
         and exists (select 1 from patient.patients p where p.id = patient_id and p.tenant_id = patient_phones.tenant_id));

revoke all on patient.patient_phones from public, anon, authenticated;
grant select on patient.patient_phones to authenticated;
grant all on patient.patient_phones to service_role;

-- -------------------------------------------------------------- writer ----
-- Sets the patient's numbers to the DESIRED state (callers pass E.164 or NULL):
--   p_phone          primary number (NULL = none)
--   p_whatsapp_same  true -> the primary row is also WhatsApp (needs p_phone)
--   p_whatsapp       otherwise: a WhatsApp number (equal to p_phone -> same row), NULL = none
-- Rows no longer needed are soft-deleted; the deprecated patients.phone mirror follows p_phone.
-- 22023 invalid input, P0002 unknown / foreign / deleted patient, 42501 no writer role at its branch.
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
  select p.id, p.tenant_id, p.registered_branch_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;
  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
     or not identity.can_access_branch(v_p.tenant_id, v_p.registered_branch_id) then
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

  -- 1. soft-delete every live row that is not needed, or whose flags change (a changed row is
  --    replaced, never re-flagged in place: swaps would trip the one-primary / one-WhatsApp keys)
  update patient.patient_phones
     set is_deleted = true
   where patient_id = v_p.id and not is_deleted
     and (is_primary is distinct from (phone_e164 is not distinct from p_phone)
          or is_whatsapp is distinct from (phone_e164 is not distinct from v_wa));
  -- 2. insert what is missing
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

  -- deprecated mirror (expand phase)
  update patient.patients set phone = p_phone where id = v_p.id and phone is distinct from p_phone;
end;
$$;
revoke all on function patient.set_patient_phones(uuid, text, boolean, text) from public, anon;
grant execute on function patient.set_patient_phones(uuid, text, boolean, text) to authenticated, service_role;

-- ---------------------------------------------------------- deprecation ----
comment on column patient.patients.phone is
  'DEPRECATED (20261019104000): mirror of the primary number in patient.patient_phones, written by '
  'patient.set_patient_phones(). Read patient_phones instead. TODO: drop in a later contract migration.';

-- ------------------------------------------------------------- backfill ----
with src as (
  select p.id, p.tenant_id, patient.to_e164(p.phone, t.default_country_code) as e164
  from patient.patients p join identity.tenants t on t.id = p.tenant_id
  where p.phone is not null
)
insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
select s.tenant_id, s.id, s.e164, true, false from src s where s.e164 is not null;

update patient.patients p set phone = ph.phone_e164
from patient.patient_phones ph
where ph.patient_id = p.id and ph.is_primary and not ph.is_deleted and p.phone is distinct from ph.phone_e164;

-- ------------------------------------------- duplicate check reads phones ----
create or replace function patient.find_duplicate_patients(
  p_tenant_id uuid,
  p_first_name text,
  p_last_name text,
  p_date_of_birth date,
  p_phone text,
  p_exclude_id uuid default null)
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
  -- 404-not-403: a tenant the caller is not a member of -> P0002; member without registry read -> 42501
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
         array_remove(array[case when m.by_name then 'name_dob' end, case when m.by_phone then 'phone' end], null)
  from patient.patients p
  cross join lateral (
    select
      coalesce(p_date_of_birth is not null and p.date_of_birth = p_date_of_birth
        and lower(btrim(p.last_name)) = lower(btrim(p_last_name))
        and lower(btrim(p.first_name)) = lower(btrim(p_first_name)), false) as by_name,
      -- any live number of the patient (phone or WhatsApp), compared on the last 10 digits
      coalesce(patient.normalize_phone(p_phone) is not null and exists (
        select 1 from patient.patient_phones ph
        where ph.tenant_id = p_tenant_id and ph.patient_id = p.id and not ph.is_deleted
          and patient.normalize_phone(ph.phone_e164) = patient.normalize_phone(p_phone)), false) as by_phone
  ) m
  where p.tenant_id = p_tenant_id
    and not p.is_deleted
    and (p_exclude_id is null or p.id <> p_exclude_id)
    and (m.by_name or m.by_phone)
  order by (m.by_name and m.by_phone) desc, p.last_name, p.first_name, p.mrn
  limit 20;
end;
$$;

-- ------------------------------------------------------ client privileges ----
-- patients.phone has a single writer now (set_patient_phones keeps the mirror)
revoke insert (phone) on patient.patients from authenticated;
revoke update (phone) on patient.patients from authenticated;
