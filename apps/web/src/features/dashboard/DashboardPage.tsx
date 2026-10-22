import type { ComponentType, ReactNode, SVGProps } from 'react'
import { Link, Navigate } from 'react-router'
import { prefetchRoute } from '../workspace/routePrefetch'
import {
  CalendarDaysIcon,
  ClipboardDocumentCheckIcon,
  QueueListIcon,
  ServerStackIcon,
  UserPlusIcon,
} from '@heroicons/react/24/outline'
import { Card as TxCard } from '@tailux/components/ui'
import { Card } from '../../components/ui/Card'
import { Illustration, type IllustrationName } from '../../components/ui/Illustration'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { can } from '../../lib/permissions'
import { useApiHealth, useAppointmentCount, usePatientStats, useQueue } from '../../lib/api/hooks'
import { isTransientError } from '../../lib/api/client'
import { addDays, localToday, zonedTimeToInstant } from '../../lib/dates'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { PendingInvitations } from '../invitations/PendingInvitations'

/** Dashboard counts refresh while the page is open (other desks work too). */
export const DASHBOARD_REFRESH_MS = 30_000

type Icon = ComponentType<SVGProps<SVGSVGElement>>

interface QuickAction {
  to: string
  state?: object
  label: string
  icon: Icon
}

/**
 * Tailux dashboard statistic card: value, label, and a decorative illustration.
 * A count is only ever the API's answer: "—" while loading, "Unavailable" on error, never a guess.
 */
function StatCard({
  label,
  value,
  error,
  illustration,
  testId,
  children,
}: {
  label: string
  value: number | undefined
  error: boolean
  illustration: IllustrationName
  testId: string
  children?: ReactNode
}) {
  return (
    <TxCard component="section" aria-label={label} className="flex items-start justify-between gap-3 p-4 sm:p-5">
      <div className="min-w-0">
        <p className="text-sm text-gray-600 dark:text-dark-200">{label}</p>
        <p
          className="mt-1 text-2xl font-semibold text-gray-800 dark:text-dark-50"
          data-testid={testId}
          aria-live="polite"
          aria-busy={value === undefined && !error}
        >
          {error ? <span className="text-base font-medium text-error-darker dark:text-error-lighter">Unavailable</span> : value === undefined ? '—' : value}
        </p>
        {children && <div className="mt-1 text-xs text-gray-600 dark:text-dark-200">{children}</div>}
      </div>
      <Illustration name={illustration} size={64} />
    </TxCard>
  )
}

export function DashboardPage() {
  const { me, tenants, activeTenant, branches: myBranches, activeBranchId, roles } = useCurrentContext()
  const { branches, branchId, branch, timeZone, timeZoneReady, setBranchId } = useBranchSelection()
  const health = useApiHealth()
  const apiStatus = health.isPending
    ? 'Checking…'
    : health.isError
      ? isTransientError(health.error)
        ? 'Waking up… try again in a moment'
        : 'Unreachable'
      : health.data.status
  const branchName = myBranches.find((b) => b.id === activeBranchId)?.name ?? 'All my branches'

  const showAppointments = can(roles, 'appointments.view')
  const showQueue = can(roles, 'queue.view')
  const showPatients = can(roles, 'patients.view')
  const today = timeZoneReady ? localToday(new Date(), timeZone) : null

  const appointments = useAppointmentCount(
    showAppointments && branchId && today
      ? { branchId, from: zonedTimeToInstant(today, '00:00', timeZone), to: zonedTimeToInstant(addDays(today, 1), '00:00', timeZone) }
      : null,
  )
  const queue = useQueue(showQueue && today ? branchId : null, today ?? '', { refetchInterval: DASHBOARD_REFRESH_MS })
  const patients = usePatientStats(branchId, showPatients && !!branchId)
  const entries = queue.data ?? []
  const waiting = queue.data ? entries.filter((e) => e.status === 'waiting').length : undefined
  const checkedIn = queue.data ? entries.filter((e) => e.status !== 'cancelled').length : undefined
  const inConsultation = entries.filter((e) => e.status === 'in_consultation').length

  const actions: QuickAction[] = (
    [
    can(roles, 'patients.write') && { to: '/patients/new', label: 'Register patient', icon: UserPlusIcon },
    can(roles, 'appointments.book') && { to: '/appointments', state: { openBooking: true }, label: 'Book appointment', icon: CalendarDaysIcon },
    can(roles, 'queue.checkIn') && { to: '/reception/check-in', label: 'Check in a patient', icon: ClipboardDocumentCheckIcon },
    showQueue && { to: '/queue', label: 'OPD queue board', icon: QueueListIcon },
    showAppointments && { to: '/appointments', label: 'Today’s appointments', icon: CalendarDaysIcon },
    ] as (QuickAction | false)[]
  ).filter((a): a is QuickAction => !!a)

  const hasStats = (showAppointments || showQueue || showPatients) && !!branchId

  // A platform operator without any hospital membership has nothing here: the console is home.
  if (me.data?.isPlatformAdmin && tenants.length === 0) return <Navigate to="/platform" replace />

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Dashboard</h1>
        {hasStats && branches.length > 1 && <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />}
      </div>
      <PendingInvitations />
      {hasStats && (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" data-testid="dashboard-stats" aria-label={`Today at ${branch?.name ?? 'this branch'}`} role="group">
          {showAppointments && (
            <StatCard label="Today’s appointments" value={appointments.data} error={appointments.isError} illustration="calendar" testId="stat-appointments">
              {timeZoneReady ? `Branch day in ${timeZone}` : null}
            </StatCard>
          )}
          {showQueue && (
            <StatCard label="Waiting in queue" value={waiting} error={queue.isError && !queue.data} illustration="clock" testId="stat-waiting">
              {queue.data ? `${inConsultation} in consultation` : null}
            </StatCard>
          )}
          {showQueue && (
            <StatCard label="Checked in today" value={checkedIn} error={queue.isError && !queue.data} illustration="tick" testId="stat-checked-in">
              Tokens issued, excluding cancelled
            </StatCard>
          )}
          {showPatients && (
            <StatCard label="Registered today" value={patients.data?.registeredToday} error={patients.isError} illustration="person" testId="stat-registered">
              {patients.data ? `${patients.data.total} ${patients.data.total === 1 ? 'patient' : 'patients'} in total at this branch` : null}
            </StatCard>
          )}
        </div>
      )}
      <div className="grid gap-4 md:grid-cols-3">
        <Card title="Context">
          <dl className="space-y-1 text-sm">
            <div>
              <dt className="inline text-gray-600 dark:text-dark-200">Hospital: </dt>
              <dd className="inline" data-testid="dashboard-tenant">
                {activeTenant?.name ?? '—'}
              </dd>
            </div>
            <div>
              <dt className="inline text-gray-600 dark:text-dark-200">Branch: </dt>
              <dd className="inline" data-testid="dashboard-branch">
                {branchName}
              </dd>
            </div>
            <div>
              <dt className="inline text-gray-600 dark:text-dark-200">Roles: </dt>
              <dd className="inline">{roles.join(', ') || '—'}</dd>
            </div>
          </dl>
        </Card>
        <Card title="API status">
          <div className="flex items-center gap-2">
            <ServerStackIcon className="size-5 text-gray-500 dark:text-dark-300" aria-hidden="true" />
            <p className="text-sm" data-testid="api-status">
              {apiStatus}
            </p>
          </div>
        </Card>
        <Card title="Quick actions">
          <ul className="space-y-2 text-sm" data-testid="dashboard-today">
            {actions.map((a) => (
              <li key={a.label}>
                <Link
                  className="inline-flex items-center gap-2 text-primary-600 underline dark:text-primary-400"
                  to={a.to}
                  state={a.state}
                  onMouseEnter={() => prefetchRoute(a.to)}
                  onFocus={() => prefetchRoute(a.to)}
                >
                  <a.icon className="size-4" aria-hidden="true" />
                  {a.label}
                </Link>
              </li>
            ))}
            {actions.length === 0 && <li className="text-gray-600 dark:text-dark-200">Nothing scheduled for your role.</li>}
          </ul>
        </Card>
      </div>
    </div>
  )
}
