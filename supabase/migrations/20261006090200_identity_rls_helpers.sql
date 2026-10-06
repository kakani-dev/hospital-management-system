-- =============================================================================
-- Sprint 0 / Migration 3: tenant-resolution helper functions used by RLS policies
--
-- SECURITY DEFINER + empty search_path: they read identity.memberships without
-- recursing through its own RLS policies, and cannot be hijacked via search_path.
-- They only ever answer questions about the CURRENT authenticated user (auth.uid()).
-- =============================================================================

-- Optional "active tenant" pin from the signed JWT. Set server-side via
-- app_metadata.tenant_id (Supabase custom access token hook / admin API). Users cannot
-- edit app_metadata, so this is not client-controlled. When absent, all of the
-- user's active memberships apply.
create or replace function identity.active_tenant_claim()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(coalesce(auth.jwt() -> 'app_metadata' ->> 'tenant_id', auth.jwt() ->> 'tenant_id'), '')::uuid
$$;

create or replace function identity.current_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct m.tenant_id
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and t.status = 'active'
    and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
$$;

create or replace function identity.has_tenant_role(p_tenant_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    where m.user_id = auth.uid()
      and m.tenant_id = p_tenant_id
      and m.status = 'active'
      and t.status = 'active'
      and m.role = any (p_roles)
      and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
  )
$$;

-- Branches of p_tenant_id the current user may act in.
create or replace function identity.current_branch_ids(p_tenant_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.id
  from identity.branches b
  where b.tenant_id = p_tenant_id
    and b.tenant_id in (select identity.current_tenant_ids())
    and exists (
      select 1 from identity.memberships m
      where m.user_id = auth.uid()
        and m.tenant_id = p_tenant_id
        and m.status = 'active'
        and (m.branch_id is null or m.branch_id = b.id)
    )
$$;

create or replace function identity.can_access_branch(p_tenant_id uuid, p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_branch_id in (select identity.current_branch_ids(p_tenant_id))
$$;

-- True when the current user shares at least one active tenant with p_user_id.
create or replace function identity.shares_tenant_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from identity.memberships m
    where m.user_id = p_user_id
      and m.status = 'active'
      and m.tenant_id in (select identity.current_tenant_ids())
  )
$$;

revoke all on function identity.active_tenant_claim() from public;
revoke all on function identity.current_tenant_ids() from public;
revoke all on function identity.has_tenant_role(uuid, text[]) from public;
revoke all on function identity.current_branch_ids(uuid) from public;
revoke all on function identity.can_access_branch(uuid, uuid) from public;
revoke all on function identity.shares_tenant_with(uuid) from public;
