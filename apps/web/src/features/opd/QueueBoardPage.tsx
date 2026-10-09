import { useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { QUEUE_REFRESH_MS, usePatientRefs, usePractitioners, useQueue, useUpdateQueueStatus } from '../../lib/api/hooks'
import { formatDayLabel, formatTime, localToday } from '../../lib/dates'
import { can } from '../../lib/permissions'
import { ApiError, problemCode } from '../../lib/api/client'
import { QUEUE_TRANSITIONS, type QueueEntry, type QueueStatus } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'

const COLUMNS: { status: QueueStatus; title: string }[] = [
  { status: 'waiting', title: 'Waiting' },
  { status: 'in_consultation', title: 'In consultation' },
  { status: 'done', title: 'Done' },
]

const ACTION_LABEL: Partial<Record<QueueStatus, string>> = { in_consultation: 'Call in', done: 'Mark done', cancelled: 'Remove' }

/** OPD queue of a branch for the branch-local day; polls every QUEUE_REFRESH_MS. */
export function QueueBoardPage({ refreshMs = QUEUE_REFRESH_MS }: { refreshMs?: number }) {
  const { me } = useCurrentContext()
  const { branches, branchId, timeZone, timeZoneReady, setBranchId } = useBranchSelection()
  const today = localToday(new Date(), timeZone)
  const queue = useQueue(timeZoneReady ? branchId : null, today, { refetchInterval: refreshMs })
  const practitioners = usePractitioners()
  const patient = usePatientRefs(queue.data ?? [])
  const update = useUpdateQueueStatus()
  const [error, setError] = useState<string | null>(null)
  const branchRoles = rolesAtBranch(me.data, branchId)
  const canAdvance = can(branchRoles, 'queue.advance')
  const canCancel = can(branchRoles, 'queue.cancel')

  const entries = [...(queue.data ?? [])].sort((a, b) => a.tokenNo - b.tokenNo)
  const cancelledCount = entries.filter((e) => e.status === 'cancelled').length
  const practitionerName = (id: string | null) => (id ? (practitioners.data?.find((p) => p.id === id)?.displayName ?? '—') : 'Any doctor')

  const move = async (entry: QueueEntry, status: Exclude<QueueStatus, 'waiting'>) => {
    setError(null)
    try {
      await update.mutateAsync({ id: entry.id, status })
    } catch (e) {
      setError(
        problemCode(e) === 'invalid_transition' || (e instanceof ApiError && e.status === 409)
          ? `Token ${entry.tokenNo} was already updated elsewhere. The board has been refreshed.`
          : e instanceof ApiError && e.status === 403
            ? 'Your role at this branch cannot make that change.'
            : `Could not update token ${entry.tokenNo}. Try again.`,
      )
    }
  }

  const allowed = (from: QueueStatus) =>
    QUEUE_TRANSITIONS[from].filter((to) => (to === 'cancelled' ? canCancel : canAdvance)) as Exclude<QueueStatus, 'waiting'>[]

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">OPD queue</h1>
        <p className="text-sm text-slate-600" data-testid="queue-updated">
          {formatDayLabel(today)} · {queue.dataUpdatedAt ? `updated ${formatTime(new Date(queue.dataUpdatedAt), timeZone)}` : 'loading'} · refreshes
          every {Math.round(refreshMs / 1000)} s
        </p>
      </div>
      <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
      <BranchNotice branchId={branchId} />
      {queue.isError && (
        <Alert tone="warning">
          {queue.error instanceof ApiError && queue.error.status === 403 ? 'You cannot view the queue of this branch.' : 'The queue is unavailable right now.'}
        </Alert>
      )}
      {error && <Alert tone="error">{error}</Alert>}
      <div className="grid gap-4 md:grid-cols-3">
        {COLUMNS.map((col) => {
          const items = entries.filter((e) => e.status === col.status)
          return (
            <Card key={col.status}>
              <section aria-labelledby={`queue-col-${col.status}`} data-testid={`queue-${col.status}`} aria-live={col.status === 'in_consultation' ? 'polite' : undefined}>
                <h2 id={`queue-col-${col.status}`} className="mb-3 text-base font-semibold">
                  {col.title} <span className="text-sm font-normal text-slate-600">({items.length})</span>
                </h2>
                {items.length === 0 && <p className="text-sm text-slate-500">None</p>}
                <ol className="space-y-2">
                  {items.map((e) => {
                    const p = patient(e)
                    return (
                      <li key={e.id} className="rounded border border-slate-200 p-2" data-testid="queue-entry" data-token={e.tokenNo}>
                        <div className="flex items-baseline gap-3">
                          <span className="text-2xl font-bold tabular-nums" aria-label={`Token ${e.tokenNo}`}>
                            {e.tokenNo}
                          </span>
                          <span className="text-sm">
                            <strong>{p === undefined ? 'Loading…' : p === null ? 'Patient unavailable' : `${p.lastName}, ${p.firstName}`}</strong>
                            <span className="block text-xs text-slate-600">
                              {practitionerName(e.practitionerId)} · {e.appointmentId ? 'appointment' : 'walk-in'} · in at{' '}
                              {formatTime(e.checkedInAt, timeZone)}
                            </span>
                          </span>
                        </div>
                        {allowed(e.status).length > 0 && (
                          <div className="mt-2 flex gap-2">
                            {allowed(e.status).map((to) => (
                              <Button
                                key={to}
                                variant={to === 'cancelled' ? 'secondary' : 'primary'}
                                className="px-3 py-1 text-xs"
                                disabled={update.isPending}
                                aria-label={`${ACTION_LABEL[to]} token ${e.tokenNo}`}
                                onClick={() => move(e, to)}
                              >
                                {ACTION_LABEL[to]}
                              </Button>
                            ))}
                          </div>
                        )}
                      </li>
                    )
                  })}
                </ol>
              </section>
            </Card>
          )
        })}
      </div>
      {cancelledCount > 0 && (
        <p className="text-sm text-slate-600" data-testid="queue-cancelled-count">
          {cancelledCount} token{cancelledCount === 1 ? '' : 's'} removed from the queue today.
        </p>
      )}
    </div>
  )
}
