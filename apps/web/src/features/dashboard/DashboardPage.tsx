import { Card } from '../../components/ui/Card'
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
          <p className="text-sm text-slate-600">Appointments, OPD queue and bed occupancy widgets arrive in Sprint 2.</p>
        </Card>
      </div>
    </div>
  )
}
