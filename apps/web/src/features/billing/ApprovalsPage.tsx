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
  const settings = useQuery({
    queryKey: ['billing', 'approval-settings'],
    queryFn: () => apiClient.billing.approvalSettings(),
  })
  const [threshold, setThreshold] = useState('')
  const [cancelPct, setCancelPct] = useState('')
  const [noShowPct, setNoShowPct] = useState('')
  const saveSettings = useMutation({
    mutationFn: () => apiClient.billing.saveApprovalSettings({
      makerCheckerThresholdPaise: threshold === '' ? (settings.data?.makerCheckerThresholdPaise ?? 20000) : Math.round(Number(threshold) * 100),
      cancelRefundPctBp: cancelPct === '' ? (settings.data?.cancelRefundPctBp ?? 10000) : Math.round(Number(cancelPct) * 100),
      noShowRefundPctBp: noShowPct === '' ? (settings.data?.noShowRefundPctBp ?? 0) : Math.round(Number(noShowPct) * 100),
    }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['billing', 'approval-settings'] }),
  })
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
      <p className="text-sm text-gray-500 dark:text-dark-300">Discounts and refunds above the cashier’s limit need someone else to approve them.</p>
      <form
        className="space-y-2 rounded-lg border border-gray-200 p-4 dark:border-dark-500"
        onSubmit={(event) => {
          event.preventDefault()
          saveSettings.mutate()
        }}
      >
        <label className="block text-sm">
          Maker-checker above (rupees)
          <input data-testid="billing-approvals-maker-checker-rupees"
            aria-label="Maker-checker above (rupees)"
            inputMode="decimal"
            className="mt-1 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            placeholder={settings.data ? String(settings.data.makerCheckerThresholdPaise / 100) : '200'}
            value={threshold}
            onChange={(event) => setThreshold(event.target.value)}
          />
        </label>
        <label className="block text-sm">
          Cancel refund (%)
          <input data-testid="billing-approvals-cancel-refund-percent"
            aria-label="Cancel refund percent"
            inputMode="decimal"
            className="mt-1 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            placeholder={settings.data ? String(settings.data.cancelRefundPctBp / 100) : '100'}
            value={cancelPct}
            onChange={(event) => setCancelPct(event.target.value)}
          />
        </label>
        <label className="block text-sm">
          No-show refund (%)
          <input data-testid="billing-approvals-no-show-refund-percent"
            aria-label="No-show refund percent"
            inputMode="decimal"
            className="mt-1 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            placeholder={settings.data ? String(settings.data.noShowRefundPctBp / 100) : '0'}
            value={noShowPct}
            onChange={(event) => setNoShowPct(event.target.value)}
          />
        </label>
        <Button type="submit" variant="secondary" disabled={saveSettings.isPending}>Save limits</Button>
        {saveSettings.isError && <Alert tone="error">Could not save the limits.</Alert>}
      </form>
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
              <input data-testid="billing-approvals-note"
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
