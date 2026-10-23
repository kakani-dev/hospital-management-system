-- Roles the signed-in caller holds in one tenant. Billing uses this to apply approval_policy
-- without reading identity.memberships. Same live-membership rules as identity.has_tenant_role.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: billing)
create or replace function identity.caller_roles_v1(p_tenant_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct m.role order by m.role), array[]::text[])
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.tenant_id = p_tenant_id
    and m.status = 'active'
    and not m.is_deleted
    and (m.branch_id is null or exists (
      select 1 from identity.branches mb where mb.id = m.branch_id and not mb.is_deleted))
    and t.status = 'active'
    and not t.is_deleted
    and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
$$;

revoke all on function identity.caller_roles_v1(uuid) from public, anon, authenticated;
grant execute on function identity.caller_roles_v1(uuid) to service_role, hms_svc_billing;

comment on function identity.caller_roles_v1(uuid) is
  'v1 (published by identity): distinct live membership roles of the caller in the tenant. Empty when there is no session. Additive changes only.';
