import { Link, Outlet } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Card } from '../../components/ui/Card'
import { Illustration } from '../../components/ui/Illustration'
import type { Capability } from '../../lib/permissions'
import { useCurrentContext } from '../tenancy/useCurrentContext'

/** Friendly "no access" page (RBAC): explains, names the roles, and offers a way back. */
export function NoAccess({ roles }: { roles: readonly string[] }) {
  return (
    <div data-testid="forbidden" className="mx-auto max-w-xl">
      <Card title="You don't have access to this page">
        <Illustration name="shield" size={80} className="mb-3" />
        <Alert tone="error">Your role in this hospital does not include access to this page.</Alert>
        <p className="mt-3 text-sm text-gray-600 dark:text-dark-200">
          Your role: <strong>{roles.length ? roles.map((r) => r.replace('_', ' ')).join(', ') : 'none'}</strong>. If you need it,
          ask your hospital admin to change your role.
        </p>
        <p className="mt-3">
          <Link to="/" className="text-primary-600 hover:underline dark:text-primary-400">
            Back to the dashboard
          </Link>
        </p>
      </Card>
    </div>
  )
}

/** Route guard, UX only — the API enforces permissions (from server-side membership) on every endpoint. */
export function RequireCapability({ capability, children }: { capability: Capability; children?: React.ReactNode }) {
  const { me, roles, has } = useCurrentContext()
  if (me.isPending) return <p role="status">Loading…</p>
  // /me failed (cold server): ContextErrorBanner explains it; never claim the role is missing.
  if (me.isError && !me.data) return null
  if (!has(capability)) return <NoAccess roles={roles} />
  return children ?? <Outlet />
}
