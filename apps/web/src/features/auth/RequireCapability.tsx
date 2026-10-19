import { Outlet } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { can, type Capability } from '../../lib/permissions'
import { useCurrentContext } from '../tenancy/useCurrentContext'

/** UX guard only — the API enforces roles and branch scope on every endpoint. */
export function RequireCapability({ capability, children }: { capability: Capability; children?: React.ReactNode }) {
  const { me, roles } = useCurrentContext()
  if (me.isPending) return <p role="status">Loading…</p>
  // /me failed (cold server): ContextErrorBanner explains it; never claim the role is missing.
  if (me.isError && !me.data) return null
  if (!can(roles, capability)) {
    return (
      <div data-testid="forbidden">
        <Alert tone="error">Your role in this hospital does not include access to this page.</Alert>
      </div>
    )
  }
  return children ?? <Outlet />
}
