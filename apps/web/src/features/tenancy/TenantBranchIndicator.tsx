import { useId } from 'react'
import { useSession } from '../auth/session'

export function TenantBranchIndicator() {
  const { session, activeMembership, switchBranch } = useSession()
  const selectId = useId()
  if (!session) return null

  const branches = session.memberships.filter((m) => m.tenantId === session.activeTenantId && m.branchId)

  return (
    <div className="flex flex-wrap items-center gap-3 text-sm" data-testid="tenant-context">
      <div>
        <span className="sr-only">Current hospital: </span>
        <span className="font-semibold text-slate-900" data-testid="tenant-name">
          {activeMembership?.tenantName ?? 'No tenant selected'}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <label htmlFor={selectId} className="text-slate-600">
          Branch
        </label>
        <select
          id={selectId}
          className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm"
          value={session.activeBranchId ?? ''}
          onChange={(e) => switchBranch(e.target.value)}
        >
          {branches.map((m) => (
            <option key={m.branchId} value={m.branchId!}>
              {m.branchName}
            </option>
          ))}
        </select>
      </div>
      <span className="rounded-full bg-brand-100 px-2 py-0.5 text-xs font-medium text-brand-800">
        {activeMembership?.role.replace('_', ' ') ?? 'no role'}
      </span>
    </div>
  )
}
