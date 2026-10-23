import { useParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { PublicLayout } from '../onboarding/PublicLayout'
import { Alert } from '../../components/ui/Alert'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { formatPaise } from './money'

/** Patient-facing bill opened from a payment link. No sign-in. Polls until it is paid. */
export function PublicPaymentPage() {
  const { token = '' } = useParams()
  const bill = useQuery({
    queryKey: ['billing', 'public', token],
    queryFn: () => apiClient.billing.publicLink(token),
    enabled: !!token,
    retry: false,
    refetchInterval: (query) => (query.state.data && query.state.data.duePaise <= 0 ? false : 2_000),
  })
  const paid = !!bill.data && (bill.data.duePaise <= 0 || bill.data.linkStatus === 'paid')
  return (
    <PublicLayout title="Your bill" subtitle="MediCore" illustration={paid ? 'tick' : 'file'}>
      {bill.isPending && <LoadingBlock label="Opening the bill" />}
      {bill.isError && <Alert tone="error">{bill.error instanceof ApiError ? 'This link is not available.' : 'Could not open the bill.'}</Alert>}
      {bill.data && (
        <div className="space-y-3" data-testid="public-bill">
          <p className="font-mono">{bill.data.billNo ?? 'Bill'}</p>
          <ul className="text-sm">
            {bill.data.lines.map((line) => (
              <li key={line.id} className="flex justify-between py-1">
                <span>{line.name}</span>
                <span className="font-mono">{formatPaise(line.netPaise + line.taxPaise)}</span>
              </li>
            ))}
          </ul>
          <p className="flex justify-between text-lg font-medium">
            <span>Due</span>
            <span className="font-mono">{formatPaise(bill.data.duePaise)}</span>
          </p>
          {paid && (
            <p className="text-center font-medium" data-testid="paid-status">
              <Illustration name="tick" size={64} className="mx-auto" />
              Paid
            </p>
          )}
        </div>
      )}
    </PublicLayout>
  )
}
