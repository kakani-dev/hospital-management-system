-- =============================================================================
-- Sprint 0 / Migration 2: Identity & Tenant service tables
-- =============================================================================

-- Tenants (hospitals). The tenant row's id IS the tenant identifier used everywhere.
create table identity.tenants (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  name        text not null,
  status      text not null default 'active',
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint tenants_code_format check (code ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  constraint tenants_name_not_blank check (length(btrim(name)) > 0),
  constraint tenants_status_valid check (status in ('active', 'suspended', 'archived')),
  constraint tenants_code_key unique (code)
);
comment on table identity.tenants is 'Hospital tenants. Created by platform operators (service role) only.';

-- Branches belong to exactly one tenant.
create table identity.branches (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  code        text not null,
  name        text not null,
  timezone    text not null default 'Asia/Kolkata',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint branches_code_format check (code ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  constraint branches_name_not_blank check (length(btrim(name)) > 0),
  -- tenant-scoped uniqueness: two hospitals may both have a branch called "main"
  constraint branches_tenant_code_key unique (tenant_id, code),
  -- target for composite FKs so child rows can never point at another tenant's branch
  constraint branches_tenant_id_id_key unique (tenant_id, id)
);

-- Global user profile (1:1 with auth.users). NOT tenant-owned on purpose: one person
-- (e.g. a visiting consultant) may hold memberships in several hospitals.
create table identity.user_profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  email         text,
  display_name  text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

-- Memberships: the ONLY source of truth for which tenant/branch a user may act in.
-- branch_id NULL = access to all branches of the tenant.
create table identity.memberships (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  user_id     uuid not null references auth.users (id) on delete cascade,
  branch_id   uuid,
  role        text not null,
  status      text not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint memberships_role_valid check (role in (
    'tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer')),
  constraint memberships_status_valid check (status in ('active', 'invited', 'suspended')),
  constraint memberships_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint memberships_tenant_user_branch_key unique nulls not distinct (tenant_id, user_id, branch_id)
);

create index memberships_user_active_idx on identity.memberships (user_id, tenant_id) where status = 'active';
create index memberships_tenant_idx on identity.memberships (tenant_id);

-- Audit-column + tenant-immutability triggers
create trigger tenants_audit_columns before insert or update on identity.tenants
  for each row execute function audit.stamp_audit_columns();
create trigger branches_audit_columns before insert or update on identity.branches
  for each row execute function audit.stamp_audit_columns();
create trigger user_profiles_audit_columns before insert or update on identity.user_profiles
  for each row execute function audit.stamp_audit_columns();
create trigger memberships_audit_columns before insert or update on identity.memberships
  for each row execute function audit.stamp_audit_columns();

create trigger branches_tenant_immutable before update on identity.branches
  for each row execute function audit.prevent_tenant_change();
create trigger memberships_tenant_immutable before update on identity.memberships
  for each row execute function audit.prevent_tenant_change();
