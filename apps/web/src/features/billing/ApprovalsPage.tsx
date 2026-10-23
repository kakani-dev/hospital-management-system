import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { formatPaise } from './money'

/** Phone-friendly queue of discounts and refunds waiting for a manager. */
export function ApprovalsPage() {
  const qc = useQueryClient()
  const [note, setNote] = useState('')
  const list = useQuery({
    queryKey: ['billing', 'approvals', 'pending'],
    queryFn: () => apiClient.billing.approvals('pending'),
  })
  const decide = useMutation({
    mutationFn: (input: { id: string; status: 'approved' | 'rejected' }) =>
      apiClient.billing.decide(input.id, { status: input.status, note: note || undefined }),
    onSettled: () => qc.invalidateQueries({ queryKey: ['billing', 'approvals'] }),
  })

  return (
    <div className="mx-auto max-w-lg space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Pending approvals</h1>
      <p className="text-sm text-gray-500 dark:text-dark-300">Discounts and refunds above the cashier’s limit.</p>
      {list.isPending && <LoadingBlock label="Loading approvals" />}
      {list.isError && <Alert tone="error">{list.error instanceof ApiError ? list.error.message : 'Could not load approvals.'}</Alert>}
      {list.data?.length === 0 && (
        <div className="py-8 text-center">
          <Illustration name="tick" size={96} className="mx-auto" />
          <p className="mt-3 text-sm text-gray-500">No approvals waiting.</p>
        </div>
      )}
      <ul className="space-y-3">
        {list.data?.map((item) => (
          <li key={item.id} className="rounded-lg border border-gray-200 p-4 dark:border-dark-500" data-testid="approval-card">
            <p className="text-base font-medium capitalize">{item.action}</p>
            <p className="font-mono text-lg">{item.amountPaise != null ? formatPaise(item.amountPaise) : '—'}</p>
            <label className="mt-3 block text-sm">
              Note
              <input
                aria-label={`Note for ${item.action}`}
                className="mt-1 w-full rounded-lg border border-gray-300 px-3 py-3 text-base dark:border-dark-500 dark:bg-dark-700"
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
            </label>
            <div className="mt-3 grid grid-cols-2 gap-2">
              <Button className="min-h-12 text-base" onClick={() => decide.mutate({ id: item.id, status: 'approved' })} disabled={decide.isPending}>
                Approve
              </Button>
              <Button className="min-h-12 text-base" variant="secondary" onClick={() => decide.mutate({ id: item.id, status: 'rejected' })} disabled={decide.isPending}>
                Reject
              </Button>
            </div>
          </li>
        ))}
      </ul>
    </div>
  )
}
