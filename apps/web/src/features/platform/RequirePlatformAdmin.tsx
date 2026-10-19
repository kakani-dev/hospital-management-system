import { Outlet } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { useMe } from '../../lib/api/hooks'

/** UX guard only: every /api/v1/platform endpoint checks identity.is_platform_admin() server-side. */
export function RequirePlatformAdmin() {
  const me = useMe()
  if (me.isPending) return <p role="status">Loading…</p>
  if (me.isError && !me.data) return null // explained by ContextErrorBanner
  if (!me.data?.isPlatformAdmin) return <Alert tone="error">Only platform operators can open the platform console.</Alert>
  return <Outlet />
}
