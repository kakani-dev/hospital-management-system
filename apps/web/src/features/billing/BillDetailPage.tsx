import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { formatPaise } from './money'
import { RefundBox } from './BillingPanel'

/** One bill: supplier GSTIN, tax split, place of supply, and a refund against a receipt. */
export function BillDetailPage() {
  const { id = '' } = useParams()
  const qc = useQueryClient()
  const [stateCode, setStateCode] = useState('')
  const [notice, setNotice] = useState<string | null>(null)
  const bill = useQuery({
    queryKey: ['billing', 'bill', id],
    queryFn: () => apiClient.billing.bill(id),
    enabled: !!id,
  })
  const savePos = async () => {
    const next = await apiClient.billing.placeOfSupply(id, stateCode)
    qc.setQueryData(['billing', 'bill', id], next)
  }

  if (bill.isPending) return <LoadingBlock label="Loading the bill" />
  if (bill.isError || !bill.data) {
    return <Alert tone="error">{bill.error instanceof ApiError ? bill.error.message : 'Bill not found.'}</Alert>
  }
  const doc = bill.data
  return (
    <div className="mx-auto max-w-lg space-y-4 p-4 sm:p-6" data-testid="bill-detail">
      <p className="text-sm"><Link className="text-primary-600 underline" to="/billing/bills">Bills</Link></p>
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">{doc.billNo ?? 'Draft bill'}</h1>
      <p className="text-sm text-gray-600 dark:text-dark-200">{doc.status}</p>
      {doc.supplier?.name && <p>{doc.supplier.name}</p>}
      {doc.supplier?.address && <p className="text-sm">{doc.supplier.address}</p>}
      <p data-testid="bill-gstin">GSTIN {doc.supplier?.gstin ?? 'Not set'}</p>
      <ul className="divide-y divide-gray-200 text-sm dark:divide-dark-500">
        {doc.lines.map((line) => (
          <li key={line.id} className="py-2">
            <span>{line.name}</span>
            {line.sacHsnCode && <span className="ml-2 text-gray-500">SAC {line.sacHsnCode}</span>}
            <span className="float-right font-mono">{formatPaise(line.netPaise + line.taxPaise)}</span>
          </li>
        ))}
      </ul>
      <p data-testid="gst-components">
        CGST {formatPaise(doc.cgstPaise ?? 0)} · SGST {formatPaise(doc.sgstPaise ?? 0)} · IGST {formatPaise(doc.igstPaise ?? 0)}
      </p>
      <p className="font-medium">Total {formatPaise(doc.totalPaise)} · Due {formatPaise(doc.duePaise)}</p>
      {doc.status === 'draft' && (
        <form
          className="flex flex-wrap items-end gap-2"
          onSubmit={(event) => {
            event.preventDefault()
            void savePos().catch((error: unknown) => setNotice(error instanceof ApiError ? error.message : 'Could not set the place of supply.'))
          }}
        >
          <label className="text-sm">
            Place of supply
            <input data-testid="billing-bill-detail-place-of-supply"
              aria-label="Place of supply"
              maxLength={2}
              className="mt-1 block w-20 rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700"
              value={stateCode || doc.placeOfSupplyState || ''}
              onChange={(event) => setStateCode(event.target.value)}
            />
          </label>
          <Button type="submit" variant="secondary">Save place of supply</Button>
        </form>
      )}
      {notice && <Alert tone="info">{notice}</Alert>}
      <RefundBox
        bill={doc}
        onNotice={setNotice}
        onChanged={(next) => {
          if (next) qc.setQueryData(['billing', 'bill', id], next)
        }}
      />
    </div>
  )
}
