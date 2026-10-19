import { useBranches, useCurrentTenant, useMe } from './api/hooks'

/**
 * Time zones for the active hospital, resolved branch → hospital, never the workstation's
 * (AUDIT-TZ B2.3): every "today", day range and time shown at a branch is in that branch's zone.
 *
 * Sources, first non-empty wins:
 * 1. `/me` accessibleBranches[].timeZone: the branch's effective zone (audit/TZ API);
 * 2. `GET /branches` `timezoneOverride`, then `timezone` (effective on the audit/TZ API, the branch's
 *    own column on the older API);
 * 3. the hospital zone from `GET /tenants/current` (only fetched when 1–2 leave a gap).
 *
 * `zoneFor(id)` is undefined while loading or when nothing is configured; callers must then wait
 * (`ready`) or show "time zone not configured", not fall back to the browser.
 */
export function useBranchTimeZones() {
  const me = useMe()
  const branches = useBranches()
  const accessible = me.data?.accessibleBranches ?? []

  const ownZone = (branchId: string): string | undefined =>
    accessible.find((b) => b.id === branchId)?.timeZone ||
    branches.data?.find((b) => b.id === branchId)?.timezoneOverride ||
    branches.data?.find((b) => b.id === branchId)?.timezone ||
    undefined

  // Without an active hospital there is no branch list to wait for (useBranches does not run).
  const listsSettled = !me.isPending && (!branches.enabled || !branches.isPending)
  const activeZone = me.data?.timeZone || (me.data?.activeBranchId ? ownZone(me.data.activeBranchId) : undefined)
  const firstBranchZone = accessible.map((b) => ownZone(b.id)).find(Boolean)
  // Only ask for the hospital zone when a branch (or the user's default) has none of its own.
  const gap = accessible.some((b) => !ownZone(b.id)) || (!activeZone && !firstBranchZone)
  const tenant = useCurrentTenant(listsSettled && gap && !!me.data?.activeTenantId)
  const tenantZone = tenant.data?.timeZone || undefined

  /** Zone for screens not tied to one branch (invitations, ages): active branch → hospital → first branch. */
  const defaultZone = activeZone ?? tenantZone ?? firstBranchZone

  return {
    zoneFor: (branchId: string | null | undefined): string | undefined =>
      (branchId ? ownZone(branchId) : undefined) ?? tenantZone ?? (branchId ? undefined : defaultZone),
    /** The hospital's own zone (audit/TZ API), when known. */
    tenantZone,
    defaultZone,
    ready: listsSettled && (!tenant.fetchStatus || tenant.fetchStatus === 'idle'),
  }
}
