-- cross-schema: approved (inserts the permission name billing.earnings into identity.role_permissions.
-- It does not read the billing schema. earnings_branches_v1 is the published branch list for that report,
-- including soft-deleted branches a tenant-wide member can still see in history.)
-- Read-only accountant. The billing role can bill, collect, discount and refund, so it is not a CA role.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table identity.memberships drop constraint memberships_role_valid;
alter table identity.memberships add constraint memberships_role_valid check (role in (
  'tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer', 'accountant'));

alter table identity.invite_links drop constraint invite_links_role_valid;
alter table identity.invite_links add constraint invite_links_role_valid check (role in (
  'tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer', 'accountant'));

do $$
declare
  r record;
begin
  for r in
    select con.conname
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class rel on rel.oid = con.conrelid
    join pg_catalog.pg_namespace nsp on nsp.oid = rel.relnamespace
    where nsp.nspname = 'identity'
      and rel.relname = 'role_permissions'
      and con.contype = 'c'
      and pg_catalog.pg_get_constraintdef(con.oid) like '%tenant_admin%'
      and pg_catalog.pg_get_constraintdef(con.oid) not like '%permission%'
  loop
    execute format('alter table identity.role_permissions drop constraint %I', r.conname);
  end loop;
end
$$;

alter table identity.role_permissions add constraint role_permissions_role_valid check (role in (
  'tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer', 'accountant'));

insert into identity.role_permissions (role, permission) values
  ('tenant_admin', 'billing.earnings'),
  ('billing', 'billing.earnings'),
  ('accountant', 'settings.view'),
  ('accountant', 'branches.view'),
  ('accountant', 'practitioners.view'),
  ('accountant', 'billing.earnings');

-- cross-schema: approved (published v1; billing earnings branch list, including soft-deleted history)
create or replace function identity.earnings_branches_v1(p_tenant_id uuid)
returns table (branch_id uuid, name text, is_deleted boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_wide boolean;
begin
  if p_tenant_id is null then
    return;
  end if;
  -- A signed-in caller must belong to the tenant and be allowed to read branches or the earnings report.
  -- Service jobs (no auth.uid) skip the membership check, same as the other published reads.
  if (select auth.uid()) is not null
     and (p_tenant_id not in (select identity.current_tenant_ids())
          or (not identity.has_tenant_permission(p_tenant_id, 'billing.earnings')
              and not identity.has_tenant_permission(p_tenant_id, 'branches.view'))) then
    return;
  end if;
  v_wide := (select auth.uid()) is null
    or exists (
      select 1 from identity.memberships m
      where m.user_id = auth.uid()
        and m.tenant_id = p_tenant_id
        and m.status = 'active'
        and not m.is_deleted
        and m.branch_id is null);
  return query
  select b.id, b.name, b.is_deleted
  from identity.branches b
  where b.tenant_id = p_tenant_id
    and (
      (not b.is_deleted and ((select auth.uid()) is null or b.id in (select identity.current_branch_ids(p_tenant_id))))
      or (b.is_deleted and v_wide));
end;
$$;

comment on function identity.earnings_branches_v1(uuid) is
  'v1 (published by identity): branches the caller may include in an earnings report. Soft-deleted branches stay visible to a tenant-wide member so history is not dropped. Empty when the caller has no access.';

revoke all on function identity.earnings_branches_v1(uuid) from public, anon, authenticated;
grant execute on function identity.earnings_branches_v1(uuid) to service_role, hms_svc_billing;
