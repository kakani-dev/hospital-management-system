import { useSearchParams } from 'react-router'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { useCurrentContext } from './useCurrentContext'

/**
 * Branch picked on a branch-scoped screen (calendar, schedules, check-in, queue). Options are the
 * server-resolved accessibleBranches from /me (a branch-scoped member only ever sees their own
 * branch); the choice lives in `?branch=` so it survives reloads and can be linked. The time zone
 * is the branch's, else the hospital's (useBranchTimeZones), never the workstation's.
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
  const resolvedZone = branchId ? zones.zoneFor(branchId) : undefined
  // Placeholder only so formatting helpers stay total; nothing date-ranged runs until a real zone
  // is known (timeZoneReady) and pages show TimeZoneNotice instead of their content.
  const timeZone = resolvedZone ?? 'UTC'

  const setBranchId = (id: string) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.set('branch', id)
        return next
      },
      { replace: true },
    )

  // Branch-local ranges must not be computed in the wrong zone: wait until the zone is resolved.
  const timeZoneReady = zones.ready && !!resolvedZone
  /** Loaded, a branch is selected, and neither it nor the hospital has a zone on record. */
  const timeZoneMissing = zones.ready && !!branchId && !resolvedZone

  return { branches, branchId, branch, timeZone, timeZoneReady, timeZoneMissing, setBranchId, loading: me.isPending }
}
