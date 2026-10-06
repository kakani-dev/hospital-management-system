import { useAuth } from '../auth/AuthProvider'
import { Button } from '../../components/ui/Button'
import { useCurrentContext } from './useCurrentContext'

/**
 * Shown when the server resolved a different hospital than the one this tab was displaying (another
 * tab/device switched it). By then AuthProvider has already cleared the query cache and remounted.
 */
export function TenantChangedBanner() {
  const { tenantNotice, dismissTenantNotice } = useAuth()
  const { tenants, activeTenant } = useCurrentContext()
  if (!tenantNotice) return null
  const previous = tenantNotice.previousTenantName ?? 'the previous hospital'
  const current = activeTenant?.name ?? tenants.find((t) => t.id === tenantNotice.resolvedTenantId)?.name ?? 'another hospital'
  return (
    <div role="alert" data-testid="tenant-changed-banner" className="border-b border-red-300 bg-red-50 px-4 py-3 text-sm text-red-900">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3">
        <p>
          <strong>Hospital changed:</strong> this session now belongs to <strong>{current}</strong> (was {previous}), probably
          because it was switched in another tab or device. All data on screen was cleared and reloaded — check the hospital above
          before you continue, or re-select the one you need.
        </p>
        <Button variant="secondary" onClick={dismissTenantNotice}>
          Dismiss
        </Button>
      </div>
    </div>
  )
}
