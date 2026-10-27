import { lazy, Suspense, useEffect, useState } from 'react'
import { Link } from 'react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { BillDocument, Receipt, ServiceItem } from '../../lib/api/types'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { formatPaise, parseRupeesToPaise, rupeesToPaise } from './money'

const UpiQr = lazy(() => import('./UpiQr').then((m) => ({ default: m.UpiQr })))

function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail || error.problem?.title || error.message
  // Transport failures (offline, CORS-blocked preflight) and local guards carry a readable message.
  if (error instanceof Error && error.message) return error.message
  return 'The bill could not be updated. Try again.'
}

/**
 * OP consult bill beside the open patient. Alt+B opens this panel. The consultation is
 * collected on the open bill, later items share that bill, and Close bill numbers it.
 */
export function BillingPanel({
  patientId,
  branchId,
  onBack,
  focusCollect = true,
}: {
  patientId: string
  branchId: string
  onBack: () => void
  /** Check-in leaves focus on the token. The patient drawer still jumps to Collect. */
  focusCollect?: boolean
}) {
  const qc = useQueryClient()
  const [generation, setGeneration] = useState(0)
  const [override, setOverride] = useState<{ generation: number; bill: BillDocument } | null>(null)
  const [qr, setQr] = useState<string | null>(null)
  const [noUpi, setNoUpi] = useState(false)
  const [share, setShare] = useState<string | null>(null)
  const [phone, setPhone] = useState('')
  const [discountRupees, setDiscountRupees] = useState('')
  const [receiptId, setReceiptId] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const summary = useQuery({
    queryKey: ['billing', 'summary', patientId, branchId],
    retry: false,
    queryFn: () => apiClient.billing.summary(patientId),
  })

  const consult = useQuery({
    queryKey: ['billing', 'consult', patientId, branchId, generation],
    retry: false,
    staleTime: Infinity,
    enabled: summary.isFetched,
    queryFn: async () => {
      if (generation === 0 && summary.data) {
        const draft = summary.data.bills.find(
          (item) => item.status === 'draft' && item.billKind === 'final' && item.branchId === branchId,
        )
        if (draft) {
          const existing = await apiClient.billing.bill(draft.id)
          if (existing.lines.length === 0) return apiClient.billing.addLine(existing.id, { code: 'CONSULT' })
          return existing
        }
      }
      const opened = await apiClient.billing.openAccount({ patientId, branchId, accountType: 'op_visit' })
      return apiClient.billing.addLine(opened.id, { code: 'CONSULT' })
    },
  })

  const bill = override?.generation === generation ? override.bill : consult.data
  const watching = !!qr && !!bill && bill.duePaise > 0
  const polled = useQuery({
    queryKey: ['billing', 'bill', bill?.id],
    queryFn: () => apiClient.billing.bill(bill!.id),
    enabled: watching,
    refetchInterval: watching ? 2_000 : false,
  })
  const shown = polled.data ?? bill

  useEffect(() => {
    if (!focusCollect || shown?.status !== 'draft') return
    const target = shown.duePaise > 0 ? 'collect-cash' : 'finalize-bill'
    document.querySelector<HTMLButtonElement>(`[data-testid="${target}"]`)?.focus()
  }, [focusCollect, shown?.id, shown?.status, shown?.duePaise])

  const remove = useMutation({
    mutationFn: (lineId: string) => apiClient.billing.removeLine(shown!.id, lineId),
    onSuccess: (next) => setOverride({ generation, bill: next }),
  })

  const run = useMutation({
    mutationFn: async (action: 'finalize' | 'cash' | 'qr' | 'whatsapp' | 'sms' | 'discount') => {
      if (!shown) throw new Error('No bill')
      if (action === 'finalize') return { bill: await apiClient.billing.finalize(shown.id) }
      if (action === 'discount') {
        const result = await apiClient.billing.discount(shown.id, {
          kind: 'flat_paise',
          value: rupeesToPaise(Number(discountRupees)),
          reasonCode: 'courtesy',
        })
        if (!('lines' in result)) {
          setNotice('This discount is above the limit. Someone else has to approve it.')
          return { bill: shown }
        }
        setNotice(null)
        return { bill: result }
      }
      if (action === 'cash') {
        const session = await apiClient.billing.ensureSession(branchId)
        if (!session.id) throw new Error('Open a counter session before taking cash.')
        const receipt = await apiClient.billing.pay(crypto.randomUUID(), {
          accountId: shown.accountId,
          kind: 'payment',
          counterSessionId: session.id,
          tenders: [{ mode: 'cash', amountPaise: shown.duePaise }],
          allocations: [{ billId: shown.id, amountPaise: shown.duePaise }],
        })
        setReceiptId(receipt.id)
        return { bill: await apiClient.billing.bill(shown.id) }
      }
      const session = await apiClient.billing.findSession(branchId).catch(() => null)
      const link = await apiClient.billing.paymentLink(shown.id, {
        channel: action,
        destination: action === 'qr' ? undefined : phone,
        ...(session?.id ? { counterSessionId: session.id } : {}),
      })
      if (action === 'qr') {
        setQr(link.upiUri ?? null)
        setNoUpi(!link.upiUri)
      }
      else setShare(link.shareStatus ?? 'queued')
      return { bill: shown }
    },
    onSuccess: (result) => {
      setOverride({ generation, bill: result.bill })
      void qc.invalidateQueries({ queryKey: ['billing', 'bill', result.bill.id] })
      void qc.invalidateQueries({ queryKey: ['billing', 'summary', patientId, branchId] })
    },
  })

  const applicable = Math.min(summary.data?.advancePaise ?? 0, shown?.duePaise ?? 0)
  const apply = useMutation({
    mutationFn: (amountPaise: number) => apiClient.billing.applyAdvance(shown!.id, { amountPaise }),
    onSuccess: (next) => {
      setOverride({ generation, bill: next })
      void qc.invalidateQueries({ queryKey: ['billing', 'summary', patientId, branchId] })
      void qc.invalidateQueries({ queryKey: ['billing', 'bill', next.id] })
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
          <li key={line.id} data-testid="bill-line" className="flex items-baseline justify-between gap-3 py-2 text-sm">
            <span>{line.name}</span>
            <span className="flex items-center gap-3">
              <span className="font-mono">{formatPaise(line.netPaise + line.taxPaise)}</span>
              {line.locked && <span className="text-xs text-gray-500">Paid</span>}
              {shown.status === 'draft' && !line.locked && (
                <Button
                  variant="ghost"
                  className="h-11 sm:h-8"
                  aria-label={`Remove ${line.name}`}
                  disabled={remove.isPending}
                  onClick={() => remove.mutate(line.id)}
                >
                  Remove
                </Button>
              )}
            </span>
          </li>
        ))}
      </ul>
      {shown.status === 'draft' && (
        <ServiceAdder billId={shown.id} onAdded={(next) => setOverride({ generation, bill: next })} />
      )}
      <TaxSplit bill={shown} />
      <p className="flex items-baseline justify-between text-base font-medium">
        <span>Total</span>
        <span className="font-mono" data-testid="bill-total">{formatPaise(shown.totalPaise)}</span>
      </p>
      {notice && <Alert tone="info">{notice}</Alert>}
      <RefundBox bill={shown} onChanged={(next) => { if (next) setOverride({ generation, bill: next }) }} onNotice={setNotice} />
      {shown.roundOffPaise !== 0 && (
        <p className="text-xs text-gray-500">Round-off {formatPaise(shown.roundOffPaise)}</p>
      )}
      {(run.isError || remove.isError || apply.isError) && (
        <Alert tone="error">{problemText(run.isError ? run.error : apply.isError ? apply.error : remove.error)}</Alert>
      )}
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
      {shown.status === 'draft' && shown.duePaise === 0 && (
        <p className="text-sm text-gray-500">Collected. Add anything else, then close the bill.</p>
      )}
      {shown.status === 'draft' && (
        <div className="flex flex-wrap gap-2">
          <Button data-testid="finalize-bill" onClick={() => run.mutate('finalize')} disabled={run.isPending}>
            Close bill
          </Button>
          <label className="flex items-center gap-2 text-sm">
            <span className="sr-only">Discount rupees</span>
            <input data-testid="billing-drawer-discount-rupees"
              aria-label="Discount rupees"
              placeholder="Discount ₹"
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
      {shown.duePaise > 0 && (
        <div className="space-y-3">
          <p className="text-sm" data-testid="bill-due">
            Due <span className="font-mono">{formatPaise(shown.duePaise)}</span>
          </p>
          {(shown.allocatedPaise ?? 0) > 0 && (
            <p className="text-xs text-gray-500">Received {formatPaise(shown.allocatedPaise ?? 0)}</p>
          )}
          {applicable > 0 && (
            <Button data-testid="apply-advance" onClick={() => apply.mutate(applicable)} disabled={apply.isPending || run.isPending}>
              Apply advance {formatPaise(applicable)}
            </Button>
          )}
          <div className="flex flex-wrap gap-2">
            <Button data-testid="collect-cash" onClick={() => run.mutate('cash')} disabled={run.isPending}>Cash</Button>
            <Button variant="secondary" onClick={() => run.mutate('qr')} disabled={run.isPending}>Show UPI QR</Button>
            <Button variant="secondary" onClick={() => setShare(share === null ? '' : null)}>Share payment link</Button>
          </div>
          {noUpi && <Alert tone="warning">This branch has no UPI ID set up. An admin can add one under Branches.</Alert>}
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
                <input data-testid="billing-drawer-share-phone"
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

/** Search the hospital catalog and add one unit. Enter adds the highlighted service. */
function ServiceAdder({ billId, onAdded }: { billId: string; onAdded: (bill: BillDocument) => void }) {
  const [q, setQ] = useState('')
  const [active, setActive] = useState(0)
  const [rateFor, setRateFor] = useState('')
  const [armed, setArmed] = useState(false)
  const debounced = useDebouncedValue(q, 200)
  const needle = debounced.trim()
  const matches = useQuery({
    queryKey: ['billing', 'service-items', 'search', needle],
    queryFn: () => apiClient.billing.serviceItems({ q: needle }),
    enabled: needle.length >= 1,
  })
  const practitioners = useQuery({
    queryKey: ['practitioners', 'bill-rate'],
    queryFn: () => apiClient.practitioners.list(),
    enabled: armed,
  })
  const add = useMutation({
    mutationFn: (item: ServiceItem) =>
      apiClient.billing.addLine(billId, { serviceItemId: item.id, ...(rateFor ? { practitionerId: rateFor } : {}) }),
    onSuccess: (bill) => {
      setQ('')
      setActive(0)
      onAdded(bill)
    },
  })
  const items = (matches.data ?? []).slice(0, 8)
  const highlighted = items[Math.min(active, Math.max(items.length - 1, 0))]

  return (
    <form
      className="space-y-2"
      aria-label="Add a service"
      onSubmit={(event) => {
        event.preventDefault()
        if (highlighted) add.mutate(highlighted)
      }}
    >
      <label className="block text-sm">
        Find a service
        <input data-testid="billing-drawer-service-search"
          aria-label="Find a service"
          role="combobox"
          aria-expanded={items.length > 0}
          aria-controls="bill-service-options"
          aria-autocomplete="list"
          type="search"
          autoComplete="off"
          className="mt-1 min-h-11 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
          placeholder="Dressing, certificate, lab…"
          value={q}
          onFocus={() => setArmed(true)}
          onChange={(event) => {
            setQ(event.target.value)
            setActive(0)
            setArmed(true)
          }}
          onKeyDown={(event) => {
            if (event.key === 'ArrowDown') {
              event.preventDefault()
              setActive((index) => Math.min(index + 1, Math.max(items.length - 1, 0)))
            } else if (event.key === 'ArrowUp') {
              event.preventDefault()
              setActive((index) => Math.max(index - 1, 0))
            } else if (event.key === 'Escape') setQ('')
          }}
        />
      </label>
      {armed && (
        <label className="block text-sm">
          Rate for
          <select data-testid="billing-drawer-rate-for"
            aria-label="Rate for"
            className="mt-1 min-h-11 w-full rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={rateFor}
            onChange={(event) => setRateFor(event.target.value)}
          >
            <option value="">Branch or hospital rate</option>
            {(practitioners.data ?? []).filter((person) => person.isActive).map((person) => (
              <option key={person.id} value={person.id}>
                {person.displayName}
              </option>
            ))}
          </select>
        </label>
      )}
      {needle.length >= 1 && !matches.isPending && items.length === 0 && <p className="text-sm text-gray-500">No matching service.</p>}
      {items.length > 0 && (
        <ul id="bill-service-options" role="listbox" aria-label="Services" className="overflow-hidden rounded-lg border border-gray-200 dark:border-dark-500">
          {items.map((item, index) => (
            <li key={item.id} role="option" aria-selected={item.id === highlighted?.id}>
              <button
                type="button"
                className={`flex min-h-11 w-full items-baseline justify-between gap-3 px-3 py-2 text-left text-sm ${item.id === highlighted?.id ? 'bg-gray-100 dark:bg-dark-600' : ''}`}
                onMouseEnter={() => setActive(index)}
                onClick={() => add.mutate(item)}
              >
                <span>{item.name}</span>
                <span className="font-mono text-gray-500">{item.code}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {add.isError && <Alert tone="error">{problemText(add.error)}</Alert>}
    </form>
  )
}

function TaxSplit({ bill }: { bill: BillDocument }) {
  const supplier = bill.supplier
  return (
    <div className="space-y-1 text-sm text-gray-600 dark:text-dark-200" data-testid="tax-split">
      {supplier?.name && <p>{supplier.name}</p>}
      {supplier?.address && <p>{supplier.address}</p>}
      <p>
        GSTIN <span data-testid="bill-gstin">{supplier?.gstin ?? 'Not set'}</span>
        {bill.placeOfSupplyState ? ` · Place of supply ${bill.placeOfSupplyState}` : ''}
      </p>
      <p data-testid="gst-components">
        CGST {formatPaise(bill.cgstPaise ?? 0)} · SGST {formatPaise(bill.sgstPaise ?? 0)} · IGST {formatPaise(bill.igstPaise ?? 0)}
      </p>
    </div>
  )
}

/** Refund against a receipt already on this bill. Pending when the amount needs another approver. */
export function RefundBox({
  bill,
  onChanged,
  onNotice,
}: {
  bill: BillDocument
  onChanged: (next: BillDocument | null) => void
  onNotice: (message: string | null) => void
}) {
  const open = (bill.payments ?? []).filter((payment) => payment.amountPaise > payment.refundedPaise)
  const [paymentId, setPaymentId] = useState(open[0]?.id ?? '')
  const [rupees, setRupees] = useState('')
  const [note, setNote] = useState<string | null>(null)
  const selected = open.find((payment) => payment.id === paymentId) ?? open[0]
  const refund = useMutation({
    mutationFn: () => {
      const amountPaise = parseRupeesToPaise(rupees)
      if (!selected || amountPaise == null) throw new Error('Enter the refund in rupees.')
      return apiClient.billing.refund(selected.id, { amountPaise })
    },
    onSuccess: async (result) => {
      if ('status' in result && result.status === 'pending') {
        const message = 'This refund needs someone else to approve it.'
        setNote(message)
        onNotice(message)
        onChanged(null)
        return
      }
      const receipt = result as Receipt
      const message = receipt.creditNoteNo
        ? `Refund ${receipt.receiptNo}. Credit note ${receipt.creditNoteNo}.`
        : `Refund ${receipt.receiptNo ?? 'recorded'}.`
      setNote(message)
      onNotice(null)
      onChanged(await apiClient.billing.bill(bill.id))
    },
  })
  if (!selected) return null
  return (
    <form
      className="space-y-2 rounded-lg border border-gray-200 p-3 dark:border-dark-500"
      data-testid="refund-box"
      onSubmit={(event) => {
        event.preventDefault()
        refund.mutate()
      }}
    >
      <p className="text-sm font-medium">Refund</p>
      {open.length > 1 && (
        <label className="block text-sm">
          Receipt
          <select data-testid="billing-drawer-refund-payment" className="mt-1 w-full rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700" value={selected.id} onChange={(event) => setPaymentId(event.target.value)}>
            {open.map((payment) => (
              <option key={payment.id} value={payment.id}>
                {payment.receiptNo ?? payment.mode} · {formatPaise(payment.amountPaise - payment.refundedPaise)} left
              </option>
            ))}
          </select>
        </label>
      )}
      <label className="block text-sm">
        Amount (rupees)
        <input data-testid="billing-drawer-refund-rupees"
          aria-label="Refund rupees"
          inputMode="decimal"
          className="mt-1 w-32 rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700"
          value={rupees}
          onChange={(event) => setRupees(event.target.value)}
        />
      </label>
      <Button type="submit" variant="secondary" disabled={refund.isPending || parseRupeesToPaise(rupees) == null}>
        Refund
      </Button>
      {note && <p className="text-sm" data-testid="refund-note">{note}</p>}
      {refund.isError && <Alert tone="error">{problemText(refund.error)}</Alert>}
    </form>
  )
}
