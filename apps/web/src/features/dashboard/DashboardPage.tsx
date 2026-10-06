import { Card } from '../../components/ui/Card'
import { useApiHealth } from '../../lib/api/hooks'
import { useSession } from '../auth/session'

export function DashboardPage() {
  const { activeMembership } = useSession()
  const health = useApiHealth()

  const apiStatus = health.isPending ? 'Checking…' : health.isError ? 'Unreachable' : health.data.status

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Dashboard</h1>
      <div className="grid gap-4 md:grid-cols-3">
        <Card title="Context">
          <dl className="space-y-1 text-sm">
            <div>
              <dt className="inline text-slate-600">Hospital: </dt>
              <dd className="inline">{activeMembership?.tenantName ?? '—'}</dd>
            </div>
            <div>
              <dt className="inline text-slate-600">Branch: </dt>
              <dd className="inline">{activeMembership?.branchName ?? 'All branches'}</dd>
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
