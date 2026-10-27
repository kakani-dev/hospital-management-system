import { useEffect } from 'react'
import { useParams, useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { useMe } from '../../lib/api/hooks'
import { formatPaise } from './money'

const MODE_LABEL: Record<string, string> = { cash: 'Cash', upi: 'UPI', card: 'Card', bank: 'Bank transfer', advance: 'Advance' }
const modeLabel = (mode: string) => MODE_LABEL[mode] ?? mode

/** Staff view of one receipt; `?print=1` prints it once everything on it has loaded (#180, #183). */
export function ReceiptPage() {
  const { receiptId = '' } = useParams()
  const me = useMe()
  const receipt = useQuery({
    queryKey: ['billing', 'receipt', receiptId],
    queryFn: () => apiClient.billing.receipt(receiptId),
    enabled: !!receiptId,
  })
  const billId = receipt.data?.allocations[0]?.billId ?? null
  const bill = useQuery({
    queryKey: ['billing', 'bill', billId],
    queryFn: () => apiClient.billing.bill(billId!),
    enabled: !!billId,
    retry: false,
  })
  const patientId = bill.data?.patientId ?? null
  const patient = useQuery({
    queryKey: ['billing', 'receipt-patient', patientId],
    queryFn: () => apiClient.patients.get(patientId!),
    enabled: !!patientId,
    retry: false,
  })
  const [search] = useSearchParams()
  const autoPrint = search.get('print') === '1'
  // print only when the optional parts have settled (loaded, failed or not needed)
  const ready =
    !!receipt.data &&
    (!billId || !bill.isPending) &&
    (!patientId || !patient.isPending) &&
    !me.isPending
  useEffect(() => {
    if (autoPrint && ready) window.print()
  }, [autoPrint, ready])

  const r = receipt.data
  const b = bill.data
  const p = patient.data
  const tz = me.data?.timeZone ?? undefined
  const when = r?.receivedAt ? new Date(r.receivedAt).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short', timeZone: tz }) : null
  const collector = r?.collectedBy ? (r.collectedBy === me.data?.userId ? (me.data?.email ?? 'You') : `Staff ${r.collectedBy.slice(0, 8)}`) : null
  const split = (r?.tenders.length ?? 0) > 1

  return (
    <div className="mx-auto max-w-lg space-y-4 p-4 sm:p-6">
      {receipt.isPending && <LoadingBlock label="Loading the receipt" />}
      {receipt.isError && <Alert tone="error">{receipt.error instanceof ApiError ? receipt.error.message : 'Could not load the receipt.'}</Alert>}
      {r && (
        <article className="space-y-3 text-sm text-gray-800 dark:text-dark-50" data-testid="receipt" data-print-area>
          <header className="border-b border-gray-200 pb-2 text-center dark:border-dark-500" data-testid="billing-receipt-hospital">
            <p className="text-base font-semibold">{b?.supplier?.name ?? 'Hospital'}</p>
            {b?.supplier?.address && <p className="text-xs">{b.supplier.address}</p>}
            {b?.supplier?.gstin && <p className="text-xs" data-testid="billing-receipt-gstin">GSTIN {b.supplier.gstin}</p>}
          </header>
          <h1 className="text-center text-lg font-semibold">Payment receipt</h1>
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            <dt className="text-gray-500">Receipt no</dt>
            <dd className="font-mono" data-testid="billing-receipt-no">{r.receiptNo ?? r.id}</dd>
            {b?.billNo && (<><dt className="text-gray-500">Bill no</dt><dd className="font-mono" data-testid="billing-receipt-bill-no">{b.billNo}</dd></>)}
            {when && (<><dt className="text-gray-500">Date</dt><dd data-testid="billing-receipt-date">{when}</dd></>)}
            {p && (<><dt className="text-gray-500">Patient</dt><dd data-testid="billing-receipt-patient">{p.lastName}, {p.firstName} · MRN {p.mrn}</dd></>)}
          </dl>
          {b && b.lines.length > 0 && (
            <table className="w-full" data-testid="billing-receipt-lines">
              <tbody>
                {b.lines.map((line) => (
                  <tr key={line.id}>
                    <td className="py-0.5">{line.name}{line.quantity > 1 ? ` × ${line.quantity}` : ''}</td>
                    <td className="py-0.5 text-right font-mono">{formatPaise(line.netPaise + line.taxPaise)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {b && b.totalPaise != null && (
            <p className="flex justify-between border-t border-gray-200 pt-1 dark:border-dark-500" data-testid="billing-receipt-bill-total">
              <span>Bill total</span><span className="font-mono">{formatPaise(b.totalPaise)}</span>
            </p>
          )}
          <p className="flex justify-between text-base font-semibold" data-testid="billing-receipt-amount">
            <span>Amount paid</span><span className="font-mono">{formatPaise(r.amountPaise)}</span>
          </p>
          <ul data-testid="billing-receipt-tenders">
            <li className="text-gray-500">Mode: {split ? 'Split' : modeLabel(r.tenders[0]?.mode ?? '')}</li>
            {r.tenders.map((tender, i) => (
              <li key={i} className="flex justify-between py-0.5">
                <span>{modeLabel(tender.mode)}{tender.reference ? ` · ${tender.reference}` : ''}</span>
                <span className="font-mono">{formatPaise(tender.amountPaise)}</span>
              </li>
            ))}
          </ul>
          {collector && <p data-testid="billing-receipt-collector">Collected by {collector}</p>}
          <Button variant="secondary" className="h-8 px-3 print:hidden" data-testid="billing-receipt-print" onClick={() => window.print()}>
            Print
          </Button>
        </article>
      )}
    </div>
  )
}
