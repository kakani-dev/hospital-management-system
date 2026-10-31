-- cross-schema: approved (shared platform helpers only: audit.* triggers and identity.current_tenant_ids() in the RLS policy, same as every tenant table)
-- #58: registration details Indian front desks capture: address (PIN code, state), emergency contact,
-- guardian (minors / dependants, "S/o, D/o, W/o, C/o"), blood group and referral source.
-- All optional at the database level; which ones are REQUIRED is a per-tenant setting
-- (patient.registration_settings) enforced by the patients service. Null = not recorded.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table patient.patients
  add column if not exists address_line text,
  add column if not exists city text,
  add column if not exists district text,
  add column if not exists state text,
  add column if not exists pin_code text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_relation text,
  add column if not exists emergency_contact_phone text,
  add column if not exists guardian_name text,
  add column if not exists guardian_relation text,
  add column if not exists blood_group text,
  add column if not exists referral_source text,
  add column if not exists referred_by text;

alter table patient.patients
  add constraint patients_address_len check (address_line is null or char_length(address_line) between 1 and 300),
  add constraint patients_city_len check (city is null or char_length(city) between 1 and 100),
  add constraint patients_district_len check (district is null or char_length(district) between 1 and 100),
  add constraint patients_state_len check (state is null or char_length(state) between 1 and 100),
  -- India Post PIN: 6 digits, never starting with 0.
  add constraint patients_pin_code check (pin_code is null or pin_code ~ '^[1-9][0-9]{5}$'),
  add constraint patients_emergency_name_len check (emergency_contact_name is null or char_length(emergency_contact_name) between 1 and 100),
  add constraint patients_emergency_relation_len check (emergency_contact_relation is null or char_length(emergency_contact_relation) between 1 and 50),
  add constraint patients_emergency_phone check (emergency_contact_phone is null or emergency_contact_phone ~ '^\+[1-9][0-9]{6,14}$'),
  add constraint patients_emergency_pair check ((emergency_contact_name is null) = (emergency_contact_phone is null)),
  add constraint patients_guardian_name_len check (guardian_name is null or char_length(guardian_name) between 1 and 100),
  add constraint patients_guardian_relation_len check (guardian_relation is null or char_length(guardian_relation) between 1 and 50),
  add constraint patients_blood_group check (blood_group is null or blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  add constraint patients_referral_source check (referral_source is null or referral_source in
    ('walk_in','self','doctor','hospital','health_camp','insurance','corporate','other')),
  add constraint patients_referred_by_len check (referred_by is null or char_length(referred_by) between 1 and 150);

grant select (address_line, city, district, state, pin_code, emergency_contact_name, emergency_contact_relation,
              emergency_contact_phone, guardian_name, guardian_relation, blood_group, referral_source, referred_by),
      insert (address_line, city, district, state, pin_code, emergency_contact_name, emergency_contact_relation,
              emergency_contact_phone, guardian_name, guardian_relation, blood_group, referral_source, referred_by),
      update (address_line, city, district, state, pin_code, emergency_contact_name, emergency_contact_relation,
              emergency_contact_phone, guardian_name, guardian_relation, blood_group, referral_source, referred_by)
  on patient.patients to hms_svc_patients, authenticated;

-- Per-tenant registration rules (owned by the patients service).
create table if not exists patient.registration_settings (
  tenant_id uuid primary key,
  guardian_required_below_age_years integer not null default 18,
  emergency_contact_required boolean not null default false,
  address_required boolean not null default false,
  referred_by_required_for_referrals boolean not null default true,
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint registration_settings_guardian_age check (guardian_required_below_age_years between 0 and 21)
);
comment on table patient.registration_settings is
  '#58: one row per tenant. A patient younger than guardian_required_below_age_years needs a guardian (0 = never). '
  'No row = defaults (18, emergency contact and address optional, referrer name required for doctor/hospital referrals).';

create trigger registration_settings_audit_columns before insert or update on patient.registration_settings
  for each row execute function audit.stamp_audit_columns();
create trigger registration_settings_tenant_immutable before update on patient.registration_settings
  for each row execute function audit.prevent_tenant_change();
create trigger registration_settings_audit_log after insert or update or delete on patient.registration_settings
  for each row execute function audit.log_row_change();
alter table patient.registration_settings enable row level security;
grant select, insert, update on patient.registration_settings to hms_svc_patients;
revoke all on patient.registration_settings from anon, authenticated, public;
create policy registration_settings_tenant on patient.registration_settings for all to hms_svc_patients
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));
