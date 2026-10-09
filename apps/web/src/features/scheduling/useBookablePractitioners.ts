import { useBranchPractitioners, useSchedules } from '../../lib/api/hooks'
import type { Practitioner } from '../../lib/api/types'
import { practitionersAtBranch } from './scheduleUtils'

/**
 * Practitioners offered for booking / walk-ins at a branch: GET /practitioners?branchId= (API v2),
 * falling back to "has a schedule at the branch" when the API rejects the parameter.
 */
export function useBookablePractitioners(branchId: string | null): Practitioner[] {
  const branchList = useBranchPractitioners(branchId)
  const needsFallback = branchList.data?.branchFiltered === false
  const schedules = useSchedules(needsFallback ? branchId : null)
  if (!branchList.data) return []
  if (!needsFallback) return branchList.data.practitioners.filter((p) => p.isActive)
  return practitionersAtBranch(branchList.data.practitioners, schedules.data ?? [])
}
