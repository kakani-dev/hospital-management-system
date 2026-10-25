import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { localToday } from '../../lib/dates'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { formatPaise } from './money'

/** Counters for one branch-day, and reconciliation for a closed session. */
export function DayEndPage() {
  const { has } = useCurrentContext()
  const { branchId, timeZone, timeZoneReady } = useBranchSelection()
  const today = timeZoneReady ? localToday(new Date(), timeZone) : ''
  const [picked, setPicked] = useState('')
  const date = picked || today
  const qc = useQueryClient()
  const report = useQuery({
    queryKey: ['billing', 'day-end', branchId, date],
    queryFn: () => apiClient.billing.dayEnd(branchId!, date),
    enabled: !!branchId && !!date,
  })
  const reconcile = useMutation({
    mutationFn: (sessionId: string) => apiClient.billing.reconcile(sessionId),
    onSettled: () => qc.invalidateQueries({ queryKey: ['billing', 'day-end'] }),
  })

  return (
    <div className="mx-auto max-w-3xl space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Day end</h1>
      <label className="block text-sm">
        Business date
        <input
          type="date"
          aria-label="Business date"
          className="mt-1 rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
          value={date}
          onChange={(e) => setPicked(e.target.value)}
        />
      </label>
      {report.isPending && <LoadingBlock label="Loading the day" />}
      {report.isError && <Alert tone="error">{report.error instanceof ApiError ? report.error.message : 'Could not load the day.'}</Alert>}
      {report.data?.length === 0 && (
        <div className="py-8 text-center">
          <Illustration name="file" size={96} className="mx-auto" />
          <p className="mt-3 text-sm text-gray-500">No counters opened this day.</p>
        </div>
      )}
      <ul className="space-y-3">
        {report.data?.map((session) => (
          <li key={session.sessionId} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-gray-200 p-4 dark:border-dark-500" data-testid="day-end-session">
            <div>
              <p className="font-medium capitalize" data-testid="session-status">{session.status.replace('_', ' ')}</p>
              <p className="text-sm text-gray-500">
                Float {formatPaise(session.openingFloatPaise)}
                {' · '}
                <span data-testid="session-expected">Expected {formatPaise(session.expectedCashPaise)}</span>
                {session.countedCashPaise != null ? ` · Counted ${formatPaise(session.countedCashPaise)}` : ''}
                {session.variancePaise != null ? (
                  <>
                    {' · '}
                    <span data-testid="session-variance">Variance {formatPaise(session.variancePaise)}</span>
                  </>
                ) : null}
              </p>
            </div>
            {has('billing.reconcile') && session.status === 'closed' && (
              <Button onClick={() => reconcile.mutate(session.sessionId)} disabled={reconcile.isPending}>
                Reconcile
              </Button>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
