import { useSearchParams } from 'react-router'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { browserTimeZone } from '../../lib/dates'
import { useCurrentContext } from './useCurrentContext'

/**
 * Branch picked on a branch-scoped screen (calendar, schedules, check-in, queue). Options are the
 * server-resolved accessibleBranches from /me (a branch-scoped member only ever sees their own
 * branch); the choice lives in `?branch=` so it survives reloads and can be linked. The time zone
 * comes from GET /api/v1/branches, falling back to the workstation's zone.
 */
export function useBranchSelection() {
  const { branches, activeBranchId, me } = useCurrentContext()
  const zones = useBranchTimeZones()
  const [params, setParams] = useSearchParams()
  const requested = params.get('branch')
  const branchId =
    (requested && branches.some((b) => b.id === requested) ? requested : null) ??
    (activeBranchId && branches.some((b) => b.id === activeBranchId) ? activeBranchId : null) ??
    branches[0]?.id ??
    null
  const branch = branches.find((b) => b.id === branchId) ?? null
  const timeZone = zones.zoneFor(branchId) ?? browserTimeZone()

  const setBranchId = (id: string) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.set('branch', id)
        return next
      },
      { replace: true },
    )

  // Branch-local ranges must not be computed in the wrong zone: wait for /branches (or its failure).
  const timeZoneReady = zones.ready

  return { branches, branchId, branch, timeZone, timeZoneReady, setBranchId, loading: me.isPending }
}
