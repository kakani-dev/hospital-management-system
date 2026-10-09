import { useSearchParams } from 'react-router'
import { useBranches } from '../../lib/api/hooks'
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
  const branchDetails = useBranches()
  const [params, setParams] = useSearchParams()
  const requested = params.get('branch')
  const branchId =
    (requested && branches.some((b) => b.id === requested) ? requested : null) ??
    (activeBranchId && branches.some((b) => b.id === activeBranchId) ? activeBranchId : null) ??
    branches[0]?.id ??
    null
  const branch = branches.find((b) => b.id === branchId) ?? null
  const timeZone = branchDetails.data?.find((b) => b.id === branchId)?.timezone || browserTimeZone()

  const setBranchId = (id: string) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.set('branch', id)
        return next
      },
      { replace: true },
    )

  return { branches, branchId, branch, timeZone, setBranchId, loading: me.isPending }
}
