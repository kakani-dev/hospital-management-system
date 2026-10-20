import { useBranchPractitioners, useSchedules } from '../../lib/api/hooks'
import type { Practitioner } from '../../lib/api/types'
import { practitionersAtBranch } from './scheduleUtils'

export type BookableStatus = 'loading' | 'error' | 'ready'

/**
 * Practitioners offered for booking / walk-ins at a branch, with the load state so callers can
 * tell "still loading" and "failed" apart from "none bookable here".
 * GET /practitioners?branchId= (API v2), falling back to "has a schedule at the branch" when the
 * API rejects the parameter.
 */
export function useBookablePractitionersState(branchId: string | null): { practitioners: Practitioner[]; status: BookableStatus } {
  const branchList = useBranchPractitioners(branchId)
  const needsFallback = branchList.data?.branchFiltered === false
  const schedules = useSchedules(needsFallback ? branchId : null)
  if (branchList.isError || (needsFallback && schedules.isError)) return { practitioners: [], status: 'error' }
  if (!branchList.data || (needsFallback && !schedules.data)) return { practitioners: [], status: 'loading' }
  if (!needsFallback) return { practitioners: branchList.data.practitioners.filter((p) => p.isActive), status: 'ready' }
  return { practitioners: practitionersAtBranch(branchList.data.practitioners, schedules.data ?? []), status: 'ready' }
}

/** Practitioners offered for booking / walk-ins at a branch (empty while loading). */
export function useBookablePractitioners(branchId: string | null): Practitioner[] {
  return useBookablePractitionersState(branchId).practitioners
}

/** "a practitioner", "a practitioner and a free slot", "a practitioner, a free slot and a patient". */
export function joinMissing(items: string[]): string {
  if (items.length <= 1) return items.join('')
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`
}
