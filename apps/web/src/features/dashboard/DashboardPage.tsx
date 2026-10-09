import { Link } from 'react-router'
import { Card } from '../../components/ui/Card'
import { can } from '../../lib/permissions'
import { useApiHealth } from '../../lib/api/hooks'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { PendingInvitations } from '../invitations/PendingInvitations'

export function DashboardPage() {
  const { activeTenant, branches, activeBranchId, roles } = useCurrentContext()
  const health = useApiHealth()
  const apiStatus = health.isPending ? 'Checking…' : health.isError ? 'Unreachable' : health.data.status
  const branchName = branches.find((b) => b.id === activeBranchId)?.name ?? 'All my branches'

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Dashboard</h1>
      <PendingInvitations />
      <div className="grid gap-4 md:grid-cols-3">
        <Card title="Context">
          <dl className="space-y-1 text-sm">
            <div>
              <dt className="inline text-slate-600">Hospital: </dt>
              <dd className="inline" data-testid="dashboard-tenant">
                {activeTenant?.name ?? '—'}
              </dd>
            </div>
            <div>
              <dt className="inline text-slate-600">Branch: </dt>
              <dd className="inline" data-testid="dashboard-branch">
                {branchName}
              </dd>
            </div>
            <div>
              <dt className="inline text-slate-600">Roles: </dt>
              <dd className="inline">{roles.join(', ') || '—'}</dd>
            </div>
          </dl>
        </Card>
        <Card title="API status">
          <p className="text-sm" data-testid="api-status">
            {apiStatus}
          </p>
        </Card>
        <Card title="Today">
          <ul className="space-y-1 text-sm" data-testid="dashboard-today">
            {can(roles, 'appointments.view') && (
              <li>
                <Link className="text-brand-800 underline" to="/appointments">
                  Today’s appointments
                </Link>
              </li>
            )}
            {can(roles, 'queue.checkIn') && (
              <li>
                <Link className="text-brand-800 underline" to="/reception/check-in">
                  Reception check-in
                </Link>
              </li>
            )}
            {can(roles, 'queue.view') && (
              <li>
                <Link className="text-brand-800 underline" to="/queue">
                  OPD queue board
                </Link>
              </li>
            )}
            {!can(roles, 'appointments.view') && !can(roles, 'queue.view') && <li className="text-slate-600">Nothing scheduled for your role.</li>}
          </ul>
        </Card>
      </div>
    </div>
  )
}
