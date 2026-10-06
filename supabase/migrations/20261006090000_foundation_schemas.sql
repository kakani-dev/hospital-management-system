-- =============================================================================
-- Sprint 0 / Migration 1: service schemas + shared audit-column helpers
--
-- Each logical service owns its own PostgreSQL schema (modular monolith).
-- Sprint 0 creates the schemas that have tables; later services
-- (appointment, clinical, billing, pharmacy, inventory, laboratory, admission,
-- notification, reporting) get their schema in the migration that introduces them.
-- =============================================================================

-- gen_random_uuid() is built into PostgreSQL 13+; no extension required.

create schema if not exists identity;
create schema if not exists patient;
create schema if not exists audit;

comment on schema identity is 'Identity & Tenant service: tenants, branches, user profiles, memberships, RBAC helpers.';
comment on schema patient  is 'Patient service: patient registry and demographics (tenant-owned).';
comment on schema audit    is 'Audit service: append-only change log and shared audit-column triggers.';

-- Lock schemas down; explicit grants are issued in the RLS migration.
revoke all on schema identity, patient, audit from public;

-- -----------------------------------------------------------------------------
-- audit.stamp_audit_columns(): maintains created_at/created_by/updated_at/updated_by.
-- created_* are immutable after insert. Actor comes from the verified JWT (auth.uid()).
-- -----------------------------------------------------------------------------
create or replace function audit.stamp_audit_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_at := new.created_at;
    new.updated_by := new.created_by;
  elsif tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- audit.prevent_tenant_change(): a row can never be moved to another tenant.
-- Defense in depth on top of RLS WITH CHECK (which would still allow a user who is a
-- member of two tenants to move a row between them).
-- -----------------------------------------------------------------------------
create or replace function audit.prevent_tenant_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tenant_id is distinct from old.tenant_id then
    raise exception 'tenant_id is immutable (table %.%)', tg_table_schema, tg_table_name
      using errcode = '42501';
  end if;
  return new;
end;
$$;
