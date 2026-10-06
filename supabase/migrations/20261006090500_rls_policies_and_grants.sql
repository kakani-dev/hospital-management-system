-- =============================================================================
-- Sprint 0 / Migration 6: Row Level Security + least-privilege grants
--
-- Model:
--   * anon            : no access to any HMS schema.
--   * authenticated   : access ONLY via RLS policies keyed on identity.memberships of auth.uid().
--   * service_role    : backend/platform operations (bypasses RLS) — never exposed to browsers.
-- Tenant id supplied by a client is never trusted: every policy derives the allowed
-- tenants from the caller's memberships (identity.current_tenant_ids()).
-- =============================================================================

alter table identity.tenants        enable row level security;
alter table identity.branches       enable row level security;
alter table identity.user_profiles  enable row level security;
alter table identity.memberships    enable row level security;
alter table patient.patients        enable row level security;
alter table audit.audit_log         enable row level security;

-- ---------------------------------------------------------------- grants ----
grant usage on schema identity, patient, audit to authenticated, service_role;

grant select on identity.tenants to authenticated;
grant update (name, settings) on identity.tenants to authenticated;

grant select, insert, update, delete on identity.branches to authenticated;
grant select on identity.user_profiles to authenticated;
grant update (display_name) on identity.user_profiles to authenticated;
grant select, insert, update, delete on identity.memberships to authenticated;

grant select on patient.patients to authenticated;
grant insert (id, tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth, sex, phone, email)
  on patient.patients to authenticated;
grant update (registered_branch_id, mrn, first_name, last_name, date_of_birth, sex, phone, email, deleted_at)
  on patient.patients to authenticated;
-- no DELETE for authenticated: patients are soft-deleted (deleted_at)

grant select on audit.audit_log to authenticated;

grant all on all tables in schema identity, patient, audit to service_role;
grant usage, select on all sequences in schema audit to service_role;

grant execute on function identity.active_tenant_claim()            to authenticated, service_role;
grant execute on function identity.current_tenant_ids()             to authenticated, service_role;
grant execute on function identity.has_tenant_role(uuid, text[])     to authenticated, service_role;
grant execute on function identity.current_branch_ids(uuid)         to authenticated, service_role;
grant execute on function identity.can_access_branch(uuid, uuid)    to authenticated, service_role;
grant execute on function identity.shares_tenant_with(uuid)         to authenticated, service_role;

-- -------------------------------------------------------------- tenants ----
create policy tenants_select_member on identity.tenants
  for select to authenticated
  using (id in (select identity.current_tenant_ids()));

create policy tenants_update_admin on identity.tenants
  for update to authenticated
  using (identity.has_tenant_role(id, array['tenant_admin']))
  with check (identity.has_tenant_role(id, array['tenant_admin']));

-- ------------------------------------------------------------- branches ----
create policy branches_select_member on identity.branches
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids()));

create policy branches_insert_admin on identity.branches
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy branches_update_admin on identity.branches
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy branches_delete_admin on identity.branches
  for delete to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']));

-- -------------------------------------------------------- user_profiles ----
create policy user_profiles_select_self_or_colleague on identity.user_profiles
  for select to authenticated
  using (id = (select auth.uid()) or identity.shares_tenant_with(id));

create policy user_profiles_update_self on identity.user_profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ---------------------------------------------------------- memberships ----
create policy memberships_select_own_or_admin on identity.memberships
  for select to authenticated
  using (
    (user_id = (select auth.uid()) and tenant_id in (select identity.current_tenant_ids()))
    or identity.has_tenant_role(tenant_id, array['tenant_admin'])
  );

create policy memberships_insert_admin on identity.memberships
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy memberships_update_admin on identity.memberships
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy memberships_delete_admin on identity.memberships
  for delete to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']));

-- ------------------------------------------------------------- patients ----
-- Read: registry roles. Write: front-desk + clinical roles, and only into a branch the
-- user can access. lab_technician / pharmacist / viewer get no registry access yet.
create policy patients_select_registry_roles on patient.patients
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']));

create policy patients_insert_registry_writers on patient.patients
  for insert to authenticated
  with check (
    identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
    and identity.can_access_branch(tenant_id, registered_branch_id)
  );

create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist']))
  with check (
    identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
    and identity.can_access_branch(tenant_id, registered_branch_id)
  );

-- ------------------------------------------------------------ audit_log ----
-- Read-only for tenant admins of the row's tenant. No write policies: rows are written
-- exclusively by the SECURITY DEFINER trigger function audit.log_row_change().
create policy audit_log_select_tenant_admin on audit.audit_log
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']));
