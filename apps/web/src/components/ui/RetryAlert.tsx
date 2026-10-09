import { Button } from './Button'

/** Error with a Retry button (writes are never retried automatically). */
export function RetryAlert({ message, onRetry, busy = false, testId = 'retry-alert' }: { message: string; onRetry: () => void; busy?: boolean; testId?: string }) {
  return (
    <div role="alert" data-testid={testId} className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-900">
      <span>{message}</span>
      <Button variant="secondary" className="px-3 py-1" disabled={busy} onClick={onRetry}>
        {busy ? 'Retrying…' : 'Retry'}
      </Button>
    </div>
  )
}
