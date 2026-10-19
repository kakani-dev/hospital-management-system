import { Outlet } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { useCurrentContext } from '../tenancy/useCurrentContext'

/** UX guard only — the API enforces tenant_admin on every admin endpoint. */
export function RequireAdmin() {
  const { me, isAdmin } = useCurrentContext()
  if (me.isPending) return <p role="status">Loading…</p>
  if (me.isError && !me.data) return null // explained by ContextErrorBanner
  if (!isAdmin) return <Alert tone="error">Only tenant admins can open this page.</Alert>
  return <Outlet />
}
