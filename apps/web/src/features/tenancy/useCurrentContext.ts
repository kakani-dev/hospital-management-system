import { useMe } from '../../lib/api/hooks'
import type { CurrentUser } from '../../lib/api/types'
import { allows, can, permissionsOf, type Capability } from '../../lib/permissions'

export interface TenantOption {
  id: string
  name: string
}

export function tenantsOf(me: CurrentUser | undefined): TenantOption[] {
  const seen = new Map<string, string>()
  for (const m of me?.memberships ?? []) if (!seen.has(m.tenantId)) seen.set(m.tenantId, m.tenantName)
  return [...seen].map(([id, name]) => ({ id, name }))
}

/**
 * Roles the user holds at `branchId` in the active tenant: tenant-wide memberships (branchId null)
 * plus memberships bound to that branch. Writes in Sprint 2 need the role *at* the row's branch.
 */
export function rolesAtBranch(me: CurrentUser | undefined, branchId: string | null): string[] {
  if (!me?.activeTenantId || !branchId) return []
  const roles = me.memberships
    .filter((m) => m.tenantId === me.activeTenantId && (m.branchId === null || m.branchId === branchId))
    .map((m) => m.role)
    // /me `roles` is the server's view of the active tenant: never grant more than that.
    .filter((r) => me.roles.includes(r))
  return [...new Set(roles)]
}

/**
 * Branch to pre-select on a form when the user has not picked one: the active branch; with
 * "All my branches", the branch of the user's own branch-bound membership (their primary branch);
 * else the first (or only) accessible branch. Only ever an id from accessibleBranches; null when
 * the user has none.
 */
export function defaultBranchId(me: CurrentUser | undefined): string | null {
  const accessible = me?.accessibleBranches ?? []
  const ok = (id: string | null | undefined): id is string => !!id && accessible.some((b) => b.id === id)
  if (ok(me?.activeBranchId)) return me!.activeBranchId!
  const primary = me?.memberships.find((m) => m.tenantId === me.activeTenantId && ok(m.branchId))?.branchId
  if (ok(primary)) return primary
  return accessible[0]?.id ?? null
}

/** Context as resolved and validated by the server (GET /api/v1/me) — the UI never decides it. */
export function useCurrentContext() {
  const me = useMe()
  const tenants = tenantsOf(me.data)
  const activeTenant = tenants.find((t) => t.id === me.data?.activeTenantId) ?? null
  const roles = me.data?.roles ?? []
  // Server-computed permissions win (never more than the server granted); older APIs: derive from roles.
  const permissions: string[] = me.data?.permissions ?? [...permissionsOf(roles)]
  const has = (capability: Capability) => (me.data?.permissions ? allows(permissions, capability) : can(roles, capability))
  return {
    me,
    tenants,
    activeTenant,
    roles,
    permissions,
    /** Tenant-wide capability check for menus, routes and page-level actions. */
    has,
    isAdmin: roles.includes('tenant_admin'),
    branches: me.data?.accessibleBranches ?? [],
    activeBranchId: me.data?.activeBranchId ?? null,
  }
}
