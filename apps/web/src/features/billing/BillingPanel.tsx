import { lazy, Suspense, useEffect, useState } from 'react'
import { Link } from 'react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { BillDocument } from '../../lib/api/types'
import { formatPaise, rupeesToPaise } from './money'

const UpiQr = lazy(() => import('./UpiQr').then((m) => ({ default: m.UpiQr })))

function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail || error.problem?.title || error.message
  return 'The bill could not be updated. Try again.'
}

/**
 * OP consult bill beside the open patient. Alt+B (or Ctrl+K, ↓, Enter) opens this panel,
 * which raises the consultation line. Finalize, then cash, a UPI QR, or a share link.
 */
export function BillingPanel({ patientId, branchId, onBack }: { patientId: string; branchId: string; onBack: () => void }) {
  const qc = useQueryClient()
  const [generation, setGeneration] = useState(0)
  const [override, setOverride] = useState<{ generation: number; bill: BillDocument } | null>(null)
  const [qr, setQr] = useState<string | null>(null)
  const [share, setShare] = useState<string | null>(null)
  const [phone, setPhone] = useState('')
  const [discountRupees, setDiscountRupees] = useState('')
  const [receiptId, setReceiptId] = useState<string | null>(null)

  const consult = useQuery({
    queryKey: ['billing', 'consult', patientId, branchId, generation],
    retry: false,
    staleTime: Infinity,
    queryFn: async () => {
      const opened = await apiClient.billing.openAccount({ patientId, branchId, accountType: 'op_visit' })
      return apiClient.billing.addLine(opened.id, { code: 'CONSULT' })
    },
  })

  const bill = override?.generation === generation ? override.bill : consult.data
  const watching = !!qr && !!bill && bill.duePaise > 0 && bill.status === 'finalized'
  const polled = useQuery({
    queryKey: ['billing', 'bill', bill?.id],
    queryFn: () => apiClient.billing.bill(bill!.id),
    enabled: watching,
    refetchInterval: watching ? 2_000 : false,
  })
  const shown = polled.data ?? bill

  useEffect(() => {
    if (shown?.status !== 'draft') return
    document.querySelector<HTMLButtonElement>('[data-testid="finalize-bill"]')?.focus()
  }, [shown?.id, shown?.status])

  const run = useMutation({
    mutationFn: async (action: 'finalize' | 'cash' | 'qr' | 'whatsapp' | 'sms' | 'discount') => {
      if (!shown) throw new Error('No bill')
      if (action === 'finalize') return { bill: await apiClient.billing.finalize(shown.id) }
      if (action === 'discount') {
        return {
          bill: await apiClient.billing.discount(shown.id, {
            kind: 'flat_paise',
            value: rupeesToPaise(Number(discountRupees)),
            reasonCode: 'courtesy',
          }),
        }
      }
      if (action === 'cash') {
        const receipt = await apiClient.billing.pay(crypto.randomUUID(), {
          accountId: shown.accountId,
          kind: 'payment',
          tenders: [{ mode: 'cash', amountPaise: shown.duePaise }],
          allocations: [{ billId: shown.id, amountPaise: shown.duePaise }],
        })
        setReceiptId(receipt.id)
        return { bill: await apiClient.billing.bill(shown.id) }
      }
      const link = await apiClient.billing.paymentLink(shown.id, {
        channel: action,
        destination: action === 'qr' ? undefined : phone,
      })
      if (action === 'qr') setQr(link.upiUri ?? null)
      else setShare(link.shareStatus ?? 'queued')
      return { bill: shown }
    },
    onSuccess: (result) => {
      setOverride({ generation, bill: result.bill })
      void qc.invalidateQueries({ queryKey: ['billing', 'bill', result.bill.id] })
    },
  })

  if (consult.isPending && !shown) return <LoadingBlock label="Raising the consultation bill" />
  if (consult.isError && !shown) {
    return (
      <div className="space-y-3">
        <Alert tone="error">{problemText(consult.error)}</Alert>
        <Button variant="secondary" onClick={onBack}>Back to the patient</Button>
      </div>
    )
  }
  if (!shown) return null

  const paid = shown.status === 'finalized' && shown.duePaise <= 0
  return (
    <div className="space-y-4" data-testid="billing-drawer">
      <p className="text-sm text-gray-500 dark:text-dark-300">
        {shown.billNo ?? 'Draft'} · {shown.status === 'draft' ? 'Not finalized' : shown.status}
      </p>
      <ul className="divide-y divide-gray-200 dark:divide-dark-500">
        {shown.lines.map((line) => (
          <li key={line.id} className="flex items-baseline justify-between gap-3 py-2 text-sm">
            <span>{line.name}</span>
            <span className="font-mono">{formatPaise(line.netPaise + line.taxPaise)}</span>
          </li>
        ))}
      </ul>
      <p className="flex items-baseline justify-between text-base font-medium">
        <span>Total</span>
        <span className="font-mono" data-testid="bill-total">{formatPaise(shown.totalPaise)}</span>
      </p>
      {shown.roundOffPaise !== 0 && (
        <p className="text-xs text-gray-500">Round-off {formatPaise(shown.roundOffPaise)}</p>
      )}
      {run.isError && <Alert tone="error">{problemText(run.error)}</Alert>}
      {paid && (
        <div className="space-y-2 text-center">
          <Illustration name="tick" size={72} className="mx-auto" />
          <p className="font-medium" data-testid="paid-status">Paid</p>
          {receiptId && (
            <Link className="text-sm text-primary-600 underline" to={`/billing/receipts/${receiptId}`}>
              View receipt
            </Link>
          )}
        </div>
      )}
      {shown.status === 'draft' && (
        <div className="flex flex-wrap gap-2">
          <Button data-testid="finalize-bill" onClick={() => run.mutate('finalize')} disabled={run.isPending}>
            Finalize
          </Button>
          <label className="flex items-center gap-2 text-sm">
            <span className="sr-only">Discount rupees</span>
            <input
              aria-label="Discount rupees"
              inputMode="decimal"
              className="w-24 rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700"
              value={discountRupees}
              onChange={(e) => setDiscountRupees(e.target.value)}
            />
          </label>
          <Button variant="secondary" onClick={() => run.mutate('discount')} disabled={run.isPending || !discountRupees}>
            Request discount
          </Button>
        </div>
      )}
      {shown.status === 'finalized' && shown.duePaise > 0 && (
        <div className="space-y-3">
          <p className="text-sm">Due <span className="font-mono">{formatPaise(shown.duePaise)}</span></p>
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => run.mutate('cash')} disabled={run.isPending}>Cash</Button>
            <Button variant="secondary" onClick={() => run.mutate('qr')} disabled={run.isPending}>Show UPI QR</Button>
            <Button variant="secondary" onClick={() => setShare(share === null ? '' : null)}>Share payment link</Button>
          </div>
          {qr && (
            <div className="space-y-2">
              <Suspense fallback={<LoadingBlock label="Preparing the QR" />}>
                <UpiQr uri={qr} />
              </Suspense>
              <p className="text-sm" data-testid="paid-status" role="status">Waiting for payment</p>
            </div>
          )}
          {share !== null && (
            <form
              className="space-y-2"
              onSubmit={(e) => {
                e.preventDefault()
              }}
            >
              <label className="block text-sm">
                Phone
                <input
                  aria-label="Phone"
                  className="mt-1 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  autoComplete="tel"
                />
              </label>
              <div className="flex gap-2">
                <Button type="button" onClick={() => run.mutate('whatsapp')} disabled={!phone || run.isPending}>WhatsApp</Button>
                <Button type="button" variant="secondary" onClick={() => run.mutate('sms')} disabled={!phone || run.isPending}>SMS</Button>
              </div>
              {share && <p className="text-sm" role="status">Link {share}</p>}
            </form>
          )}
        </div>
      )}
      <div className="flex gap-2">
        <Button variant="ghost" onClick={onBack}>Back to the patient</Button>
        <Button variant="ghost" onClick={() => { setQr(null); setShare(null); setOverride(null); setGeneration((n) => n + 1) }}>
          New bill
        </Button>
      </div>
    </div>
  )
}
