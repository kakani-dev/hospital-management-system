-- =============================================================================
-- Sprint 0 / Migration 4: Patient service — patient registry
-- =============================================================================

create table patient.patients (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references identity.tenants (id) on delete restrict,
  registered_branch_id  uuid not null,
  mrn                   text not null,
  first_name            text not null,
  last_name             text not null,
  date_of_birth         date,
  sex                   text not null default 'unknown',
  phone                 text,
  email                 text,
  deleted_at            timestamptz,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint patients_mrn_format check (mrn ~ '^[A-Za-z0-9-]{1,32}$'),
  constraint patients_names_not_blank check (length(btrim(first_name)) > 0 and length(btrim(last_name)) > 0),
  constraint patients_sex_valid check (sex in ('female', 'male', 'other', 'unknown')),
  constraint patients_dob_sane check (date_of_birth is null or date_of_birth >= date '1900-01-01'),
  -- the registering branch must belong to the same tenant as the patient
  constraint patients_branch_same_tenant
    foreign key (tenant_id, registered_branch_id) references identity.branches (tenant_id, id) on delete restrict,
  -- MRN is unique per hospital, not globally
  constraint patients_tenant_mrn_key unique (tenant_id, mrn),
  constraint patients_tenant_id_id_key unique (tenant_id, id)
);

comment on table patient.patients is 'Tenant-owned patient registry. Soft delete via deleted_at. SYNTHETIC data only outside production.';

create index patients_tenant_name_idx on patient.patients (tenant_id, lower(last_name), lower(first_name)) where deleted_at is null;
create index patients_tenant_branch_idx on patient.patients (tenant_id, registered_branch_id);

create trigger patients_audit_columns before insert or update on patient.patients
  for each row execute function audit.stamp_audit_columns();
create trigger patients_tenant_immutable before update on patient.patients
  for each row execute function audit.prevent_tenant_change();
