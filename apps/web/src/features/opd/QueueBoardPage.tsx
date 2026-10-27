import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Card } from '../../components/ui/Card'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { prefetchPatientRecord } from '../patients/prefetchPatient'
import { useWorkspace } from '../workspace/WorkspaceProvider'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { mutationKeys, QUEUE_REFRESH_MS, useCloseQueueDay, usePatientRefs, usePendingMutationIds, usePractitioners, useQueue, useUpdateQueueStatus, type QueueStatusChange } from '../../lib/api/hooks'
import { transientWriteMessage } from '../../lib/api/errors'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { formatDayLabel, formatTime, localToday } from '../../lib/dates'
import { can } from '../../lib/permissions'
import { ApiError, apiClient, problemCode } from '../../lib/api/client'
import { formatPaise } from '../billing/money'
import { QUEUE_TRANSITIONS, type QueueEntry, type QueueStatus } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'
import { StartConsultationButton } from '../clinical/StartConsultationButton'
import { VitalsPanel } from '../clinical/VitalsPanel'

const COLUMNS: { status: QueueStatus; title: string }[] = [
  { status: 'waiting', title: 'Waiting' },
  { status: 'in_consultation', title: 'In consultation' },
  { status: 'done', title: 'Done' },
  { status: 'expired', title: 'Closed' },
]

const ACTION_LABEL: Partial<Record<QueueStatus, string>> = { in_consultation: 'Call in', done: 'Mark done', cancelled: 'Remove' }

/** OPD queue of a branch for the branch-local day; polls every QUEUE_REFRESH_MS. */
export function QueueBoardPage({ refreshMs = QUEUE_REFRESH_MS }: { refreshMs?: number }) {
  const { me } = useCurrentContext()
  const { openPatient } = useWorkspace()
  const qc = useQueryClient()
  const { branches, branchId, timeZone, timeZoneReady, timeZoneMissing, setBranchId } = useBranchSelection()
  const today = localToday(new Date(), timeZone)
  const queue = useQueue(timeZoneReady ? branchId : null, today, { refetchInterval: refreshMs })
  const practitioners = usePractitioners()
  const patient = usePatientRefs(queue.data ?? [])
  const update = useUpdateQueueStatus()
  const closeDay = useCloseQueueDay()
  const [confirmClose, setConfirmClose] = useState(false)
  const [closeReason, setCloseReason] = useState('')
  const [reasonError, setReasonError] = useState<string | null>(null)
  const [error, setError] = useState<{ message: string; retry: (() => void) | null } | null>(null)
  const saving = usePendingMutationIds<QueueStatusChange>(mutationKeys.queueStatus, (v) => v.id)
  const branchRoles = rolesAtBranch(me.data, branchId)
  const canAdvance = can(branchRoles, 'queue.advance')
  const canCancel = can(branchRoles, 'queue.cancel')
  // #142 / QUE-007: today cannot be closed before it ends in the branch zone; the end-of-day job
  // closes it after branch-local midnight. Only a hospital admin may close it early, with a reason.
  const canCloseDay = can(branchRoles, 'queue.cancel')
  const canCloseEarly = canCloseDay && branchRoles.includes('tenant_admin')
  const canBook = can(branchRoles, 'appointments.book')
  // doctors: follow-ups of their own appointment visits only (the server checks ownership)
  const canFollowUpOwn = can(branchRoles, 'appointments.bookFollowUp')
  const canConsult = can(branchRoles, 'clinical.write')
  // #104: nurse (and doctor) record triage vitals from the queue
  const canVitals = can(branchRoles, 'clinical.vitals')
  const canCollect = can(branchRoles, 'billing.bill')
  const [vitalsFor, setVitalsFor] = useState<string | null>(null)

  const entries = [...(queue.data ?? [])].sort((a, b) => a.tokenNo - b.tokenNo)
  const cancelledCount = entries.filter((e) => e.status === 'cancelled').length
  const waitingCount = entries.filter((e) => e.status === 'waiting').length

  const close = async () => {
    if (!branchId) return
    const reason = closeReason.trim()
    if (reason.length < 3 || reason.length > 500) {
      setReasonError('Give a reason of 3 to 500 characters for closing before the day ends.')
      return
    }
    setReasonError(null)
    setError(null)
    try {
      const result = await closeDay.mutateAsync({ branchId, date: today, reason })
      setConfirmClose(false)
      setCloseReason('')
      setError({
        message:
          result.expiredCount === 0
            ? 'The day is closed. No tokens were still waiting.'
            : `Closed the day. ${result.expiredCount} waiting token${result.expiredCount === 1 ? '' : 's'} expired.`,
        retry: null,
      })
    } catch (e) {
      const transient = transientWriteMessage(e, 'close the queue')
      setError({
        message: transient ?? (e instanceof ApiError ? (e.problem?.detail ?? 'Could not close the queue.') : 'Could not close the queue.'),
        retry: transient ? () => void close() : null,
      })
    }
  }
  const practitionerName = (id: string | null) => (id ? (practitioners.data?.find((p) => p.id === id)?.displayName ?? '—') : 'Any doctor')

  // Optimistic: the card moves at once (useUpdateQueueStatus), and rolls back on failure.
  const move = async (entry: QueueEntry, status: Exclude<QueueStatus, 'waiting'>) => {
    setError(null)
    try {
      await update.mutateAsync({ id: entry.id, status })
    } catch (e) {
      const transient = transientWriteMessage(e, `update token ${entry.tokenNo}`)
      if (transient) {
        setError({ message: transient, retry: () => void move(entry, status) })
        return
      }
      const message =
        problemCode(e) === 'invalid_transition' || (e instanceof ApiError && e.status === 409)
          ? `Token ${entry.tokenNo} was already updated elsewhere. The board has been refreshed.`
          : e instanceof ApiError && e.status === 403
            ? 'Your role at this branch cannot make that change.'
            : `Could not update token ${entry.tokenNo}. Try again.`
      setError({ message, retry: null })
    }
  }

  const allowed = (from: QueueStatus) =>
    QUEUE_TRANSITIONS[from].filter((to) => (to === 'cancelled' ? canCancel : canAdvance)) as Exclude<QueueStatus, 'waiting'>[]

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">OPD queue</h1>
        {canCloseEarly && branchId && (
          <Button
            variant="secondary"
            data-testid="queue-close-day-button"
            disabled={closeDay.isPending || !timeZoneReady}
            onClick={() => {
              setReasonError(null)
              setConfirmClose(true)
            }}
          >
            Close today early
          </Button>
        )}
        {canCloseDay && !canCloseEarly && branchId && (
          <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="queue-auto-close-hint">
            Today&apos;s queue closes automatically after midnight (branch time). Only a hospital admin can close it early.
          </p>
        )}
        <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="queue-updated">
          {formatDayLabel(today)} · {queue.dataUpdatedAt ? `updated ${formatTime(new Date(queue.dataUpdatedAt), timeZone)}` : 'loading'} · refreshes
          every {Math.round(refreshMs / 1000)} s
        </p>
      </div>
      <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
      <BranchNotice branchId={branchId} timeZoneMissing={timeZoneMissing} />
      {queue.isPending && <LoadingBlock label="Loading the queue" />}
      {queue.isError && (
        <Alert tone="warning">
          {queue.error instanceof ApiError && queue.error.status === 403 ? 'You cannot view the queue of this branch.' : 'The queue is unavailable right now.'}
        </Alert>
      )}
      {error &&
        (error.retry ? (
          <RetryAlert message={error.message} onRetry={error.retry} />
        ) : error.message.startsWith('Closed the day') || error.message.startsWith('The day is closed') ? (
          <Alert tone="info">{error.message}</Alert>
        ) : (
          <Alert tone="error">{error.message}</Alert>
        ))}
      {queue.data && entries.length === 0 && (
        <div className="flex flex-col items-center gap-2 py-2 text-center">
          <Illustration name="clock" size={96} />
          <p className="text-sm text-gray-600 dark:text-dark-200">No tokens on the board yet.</p>
        </div>
      )}
      <div className={`grid gap-4 md:grid-cols-2 xl:grid-cols-4 ${queue.isPlaceholderData ? 'opacity-60' : ''}`} aria-busy={queue.isFetching && !queue.data}>
        {COLUMNS.map((col) => {
          const items = entries.filter((e) => e.status === col.status)
          return (
            <Card key={col.status}>
              <section aria-labelledby={`queue-col-${col.status}`} data-testid={`queue-${col.status}`} aria-live={col.status === 'in_consultation' ? 'polite' : undefined}>
                <h2 id={`queue-col-${col.status}`} className="mb-3 text-base font-semibold">
                  {col.title} <span className="text-sm font-normal text-gray-600 dark:text-dark-200">({items.length})</span>
                </h2>
                {items.length === 0 && <p className="text-sm text-gray-500 dark:text-dark-300">None</p>}
                <ol className="space-y-2">
                  {items.map((e) => {
                    const p = patient(e)
                    return (
                      <li
                        key={e.id}
                        className={`rounded border p-2 ${saving.includes(e.id) ? 'border-primary-300 dark:border-primary-500/50 bg-primary-50 dark:bg-primary-500/15' : 'border-gray-200 dark:border-dark-500'}`}
                        data-testid="queue-entry"
                        data-token={e.tokenNo}
                        aria-busy={saving.includes(e.id)}
                      >
                        <div className="flex items-baseline gap-3">
                          <span className="text-2xl font-bold tabular-nums" aria-label={`Token ${e.tokenNo}`}>
                            {e.tokenNo}
                          </span>
                          {saving.includes(e.id) && (
                            <span className="text-xs font-medium text-primary-600 dark:text-primary-400" data-testid="queue-entry-saving">
                              Saving…
                            </span>
                          )}
                          <span className="text-sm">
                            {p === undefined ? (
                              <strong>Loading…</strong>
                            ) : p === null ? (
                              <strong>Patient unavailable</strong>
                            ) : (
                              <button
                                type="button"
                                className="font-semibold text-primary-600 underline dark:text-primary-400"
                                data-testid="open-patient-context"
                                onMouseEnter={() => prefetchPatientRecord(qc, p.id)}
                                onFocus={() => prefetchPatientRecord(qc, p.id)}
                                onClick={() => openPatient({ id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName })}
                              >
                                {p.lastName}, {p.firstName}
                              </button>
                            )}
                            <span className="block text-xs text-gray-600 dark:text-dark-200">
                              {practitionerName(e.practitionerId)} · {e.appointmentId ? 'appointment' : 'walk-in'} · in at{' '}
                              {formatTime(e.checkedInAt, timeZone)}
                            </span>
                          </span>
                        </div>
                        {(canBook || (canFollowUpOwn && !!e.appointmentId)) && p && (e.status === 'done' || e.status === 'in_consultation') && (
                          <button
                            type="button"
                            className="mt-2 text-xs font-medium text-primary-600 underline dark:text-primary-400"
                            onClick={() =>
                              openPatient(
                                { id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName },
                                { mode: 'book', followUp: { practitionerId: e.practitionerId, parentAppointmentId: e.appointmentId } },
                              )
                            }
                          >
                            Book follow-up
                          </button>
                        )}
                        {canVitals && p && (e.status === 'waiting' || e.status === 'in_consultation') && (
                          <button
                            type="button"
                            data-testid="queue-vitals-toggle"
                            aria-expanded={vitalsFor === e.id}
                            aria-label={`Vitals for token ${e.tokenNo}`}
                            className="mt-2 block text-xs font-medium text-primary-600 underline dark:text-primary-400"
                            onClick={() => setVitalsFor((cur) => (cur === e.id ? null : e.id))}
                          >
                            {vitalsFor === e.id ? 'Hide vitals' : 'Vitals'}
                          </button>
                        )}
                        {canCollect && p && e.status !== 'cancelled' && (
                          <Button
                            className="mt-2 h-8 px-3 text-xs"
                            data-testid="queue-row-collect"
                            aria-label={`Collect for token ${e.tokenNo}`}
                            onClick={() =>
                              openPatient({ id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName }, { mode: 'bill' })
                            }
                          >
                            <CollectLabel patientId={p.id} branchId={branchId} />
                          </Button>
                        )}
                        {canVitals && vitalsFor === e.id && <VitalsPanel queueEntryId={e.id} canRecord />}
                        {canConsult && p && e.status === 'in_consultation' && (
                          <StartConsultationButton queueEntryId={e.id} tokenNo={e.tokenNo} onError={(message) => setError({ message, retry: null })} />
                        )}
                        {allowed(e.status).length > 0 && (
                          <div className="mt-2 flex gap-2">
                            {allowed(e.status).map((to) => (
                              <Button
                                key={to}
                                variant={to === 'cancelled' ? 'secondary' : 'primary'}
                                className="px-3 py-1 text-xs"
                                disabled={saving.includes(e.id)}
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
      <ConfirmDialog
        open={confirmClose}
        title="Close today's queue before the day ends?"
        confirmLabel="Expire waiting tokens"
        busy={closeDay.isPending}
        onCancel={() => {
          setConfirmClose(false)
          setReasonError(null)
        }}
        onConfirm={() => void close()}
      >
        <p>
          {waitingCount === 0
            ? 'No tokens are waiting. Tokens already with a doctor stay as they are.'
            : `${waitingCount} waiting token${waitingCount === 1 ? '' : 's'} will be marked closed for this branch's day. Tokens already with a doctor stay as they are.`}
        </p>
        <p className="mt-2">The day has not ended yet in the branch time zone. The reason is kept with the closed tokens.</p>
        <label className="mt-3 block text-sm font-medium">
          Reason for closing early
          <textarea
            className="mt-1 min-h-20 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700"
            data-testid="queue-close-reason"
            value={closeReason}
            maxLength={500}
            onChange={(event) => setCloseReason(event.target.value)}
          />
        </label>
        {reasonError && (
          <p className="mt-1 text-sm text-red-600" role="alert" data-testid="queue-close-reason-error">
            {reasonError}
          </p>
        )}
      </ConfirmDialog>
      {cancelledCount > 0 && (
        <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="queue-cancelled-count">
          {cancelledCount} token{cancelledCount === 1 ? '' : 's'} removed from the queue today.
        </p>
      )}
    </div>
  )
}

/** "Collect ₹X" when the patient has an open bill due at this branch (#180). Shares the bill panel's cache. */
function CollectLabel({ patientId, branchId }: { patientId: string; branchId: string | null }) {
  const summary = useQuery({
    queryKey: ['billing', 'summary', patientId, branchId],
    retry: false,
    staleTime: 30_000,
    queryFn: () => apiClient.billing.summary(patientId),
  })
  const due = (summary.data?.bills ?? [])
    .filter((bill) => bill.status === 'draft' && bill.billKind === 'final' && bill.branchId === branchId)
    .reduce((sum, bill) => sum + Math.max(bill.duePaise, 0), 0)
  return <span data-testid="queue-row-collect-amount">{due > 0 ? `Collect ${formatPaise(due)}` : 'Collect'}</span>
}
