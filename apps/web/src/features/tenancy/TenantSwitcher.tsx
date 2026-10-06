import { useId } from 'react'
import { useAuth } from '../auth/AuthProvider'
import { useSwitchContext } from '../../lib/api/hooks'
import { useCurrentContext } from './useCurrentContext'

export function TenantSwitcher() {
  const { refresh } = useAuth()
  const { me, tenants, activeTenant, roles, branches, activeBranchId } = useCurrentContext()
  const switchContext = useSwitchContext(refresh)
  const tenantSelectId = useId()
  const branchSelectId = useId()

  if (me.isPending) return <span className="text-sm text-slate-500">Loading context…</span>
  if (me.isError || !me.data) return <span className="text-sm text-red-700">Context unavailable</span>
  if (tenants.length === 0) {
    return (
      <span className="text-sm text-slate-600" data-testid="tenant-name">
        No hospital memberships
      </span>
    )
  }

  const busy = switchContext.isPending
  return (
    <div className="flex flex-wrap items-center gap-3 text-sm" data-testid="tenant-context">
      <div className="flex items-center gap-2">
        <label htmlFor={tenantSelectId} className="text-slate-600">
          Hospital
        </label>
        {tenants.length > 1 ? (
          <select
            id={tenantSelectId}
            className="rounded-md border border-slate-300 bg-white px-2 py-1"
            value={activeTenant?.id ?? ''}
            disabled={busy}
            onChange={(e) => switchContext.mutate({ tenantId: e.target.value, branchId: null })}
          >
            {!activeTenant && <option value="">Select…</option>}
            {tenants.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        ) : (
          <output id={tenantSelectId} className="font-semibold text-slate-900">
            {activeTenant?.name ?? tenants[0]!.name}
          </output>
        )}
        <span className="sr-only" data-testid="tenant-name">
          {activeTenant?.name}
        </span>
      </div>
      {activeTenant && (
        <div className="flex items-center gap-2">
          <label htmlFor={branchSelectId} className="text-slate-600">
            Branch
          </label>
          <select
            id={branchSelectId}
            className="rounded-md border border-slate-300 bg-white px-2 py-1"
            value={activeBranchId ?? ''}
            disabled={busy}
            onChange={(e) => switchContext.mutate({ tenantId: activeTenant.id, branchId: e.target.value || null })}
          >
            {branches.length > 1 && <option value="">All my branches</option>}
            {branches.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </select>
        </div>
      )}
      <span className="rounded-full bg-brand-100 px-2 py-0.5 text-xs font-medium text-brand-800" data-testid="active-roles">
        {roles.length ? roles.map((r) => r.replace('_', ' ')).join(', ') : 'no role'}
      </span>
      {switchContext.isError && (
        <span role="alert" className="text-xs text-red-700">
          Switch denied
        </span>
      )}
    </div>
  )
}
