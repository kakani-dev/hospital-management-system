import { useEffect } from 'react'
import { useParams, useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { formatPaise } from './money'

/** Staff view of one receipt. */
export function ReceiptPage() {
  const { receiptId = '' } = useParams()
  const receipt = useQuery({
    queryKey: ['billing', 'receipt', receiptId],
    queryFn: () => apiClient.billing.receipt(receiptId),
    enabled: !!receiptId,
  })
  const [search] = useSearchParams()
  const autoPrint = search.get('print') === '1'
  useEffect(() => {
    if (autoPrint && receipt.data) window.print()
  }, [autoPrint, receipt.data])
  return (
    <div className="mx-auto max-w-lg space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Receipt</h1>
      {receipt.isPending && <LoadingBlock label="Loading the receipt" />}
      {receipt.isError && <Alert tone="error">{receipt.error instanceof ApiError ? receipt.error.message : 'Could not load the receipt.'}</Alert>}
      {receipt.data && (
        <article className="space-y-3" data-testid="receipt">
          <Illustration name="file" size={72} />
          <p className="font-mono text-lg">{receipt.data.receiptNo ?? receipt.data.id}</p>
          <p className="text-2xl font-medium">{formatPaise(receipt.data.amountPaise)}</p>
          <ul className="text-sm">
            {receipt.data.tenders.map((tender, i) => (
              <li key={i} className="flex justify-between py-1">
                <span className="capitalize">{tender.mode}</span>
                <span className="font-mono">{formatPaise(tender.amountPaise)}</span>
              </li>
            ))}
          </ul>
          <Button variant="secondary" className="h-8 px-3 print:hidden" data-testid="billing-receipt-print" onClick={() => window.print()}>
            Print
          </Button>
        </article>
      )}
    </div>
  )
}
