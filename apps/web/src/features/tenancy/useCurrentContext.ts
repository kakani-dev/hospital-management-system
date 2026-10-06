import { useMe } from '../../lib/api/hooks'
import type { CurrentUser } from '../../lib/api/types'

export interface TenantOption {
  id: string
  name: string
}

export function tenantsOf(me: CurrentUser | undefined): TenantOption[] {
  const seen = new Map<string, string>()
  for (const m of me?.memberships ?? []) if (!seen.has(m.tenantId)) seen.set(m.tenantId, m.tenantName)
  return [...seen].map(([id, name]) => ({ id, name }))
}

/** Context as resolved and validated by the server (GET /api/v1/me) — the UI never decides it. */
export function useCurrentContext() {
  const me = useMe()
  const tenants = tenantsOf(me.data)
  const activeTenant = tenants.find((t) => t.id === me.data?.activeTenantId) ?? null
  const roles = me.data?.roles ?? []
  return {
    me,
    tenants,
    activeTenant,
    roles,
    isAdmin: roles.includes('tenant_admin'),
    branches: me.data?.accessibleBranches ?? [],
    activeBranchId: me.data?.activeBranchId ?? null,
  }
}
