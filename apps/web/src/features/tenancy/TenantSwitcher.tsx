import { useId } from 'react'
import { useAuth } from '../auth/AuthProvider'
import { useSwitchContext } from '../../lib/api/hooks'
import { useCurrentContext } from './useCurrentContext'
import { Badge } from '@tailux/components/ui'

// Tailux form-select look, compact for the header.
const selectClass =
  'form-select-base form-select h-8 rounded-lg border-gray-300 py-1 pr-8 text-xs-plus hover:border-gray-400 focus:border-primary-600 dark:border-dark-450 dark:bg-dark-900 dark:hover:border-dark-400 dark:focus:border-primary-500'

/**
 * Hospital/branch context. `inline` sits in the header (md and up); `stacked` is the full-width
 * version the shell renders inside the navigation drawer on small screens (demo2's responsive
 * header: the context collapses into the sidebar and the header keeps a compact summary).
 */
export function TenantSwitcher({ variant = 'inline' }: { variant?: 'inline' | 'stacked' }) {
  const stacked = variant === 'stacked'
  const { refresh, resetCache, expectTenant } = useAuth()
  const { me, tenants, activeTenant, roles, branches, activeBranchId } = useCurrentContext()
  const switchContext = useSwitchContext({ refresh, resetCache, expectTenant })
  const tenantSelectId = useId()
  const branchSelectId = useId()

  if (me.isPending) return <span className="text-xs-plus text-gray-500 dark:text-dark-300">Loading context…</span>
  if (me.isError || !me.data) return <span className="text-xs-plus text-error-darker dark:text-error-lighter">Context unavailable</span>
  if (tenants.length === 0) {
    return (
      <span className="text-xs-plus text-gray-600 dark:text-dark-200" data-testid="tenant-name">
        {me.data.isPlatformAdmin ? 'Platform console (no hospital access)' : 'No hospital memberships'}
      </span>
    )
  }

  const busy = switchContext.isPending
  return (
    <div
      className={stacked ? 'flex flex-col gap-3 text-xs-plus' : 'flex flex-wrap items-center gap-x-3 gap-y-1 text-xs-plus'}
      data-testid="tenant-context"
      data-variant={variant}
    >
      <div className={stacked ? 'flex flex-col gap-1' : 'flex items-center gap-2'}>
        <label htmlFor={tenantSelectId} className="text-gray-500 dark:text-dark-300">
          Hospital
        </label>
        {tenants.length > 1 ? (
          <select
            id={tenantSelectId}
            className={stacked ? `${selectClass} w-full` : selectClass}
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
          <output id={tenantSelectId} className={stacked ? 'break-words font-medium text-gray-800 dark:text-dark-100' : 'font-medium text-gray-800 dark:text-dark-100'}>
            {activeTenant?.name ?? tenants[0]!.name}
          </output>
        )}
        <span className="sr-only" data-testid="tenant-name">
          {activeTenant?.name}
        </span>
      </div>
      {activeTenant && (
        <div className={stacked ? 'flex flex-col gap-1' : 'flex items-center gap-2'}>
          <label htmlFor={branchSelectId} className="text-gray-500 dark:text-dark-300">
            Branch
          </label>
          <select
            id={branchSelectId}
            className={stacked ? `${selectClass} w-full` : selectClass}
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
      <Badge color="primary" variant="soft" className={stacked ? 'self-start rounded-full capitalize' : 'rounded-full capitalize'} data-testid="active-roles">
        {roles.length ? roles.map((r) => r.replace('_', ' ')).join(', ') : 'no role'}
      </Badge>
      {switchContext.isError && (
        <span role="alert" className="text-xs text-error-darker dark:text-error-lighter">
          Switch denied
        </span>
      )}
    </div>
  )
}
