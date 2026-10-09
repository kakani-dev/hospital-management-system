import { useBranches } from './api/hooks'

/**
 * IANA time zone of a branch from GET /api/v1/branches, or undefined while loading / unknown
 * (callers then fall back to the workstation's zone, e.g. localToday(now, undefined)).
 */
export function useBranchTimeZones() {
  const branches = useBranches()
  return {
    zoneFor: (branchId: string | null | undefined): string | undefined =>
      (branchId ? branches.data?.find((b) => b.id === branchId)?.timezone : undefined) || undefined,
    ready: !branches.isPending,
  }
}
