import { Button } from './Button'

/** Error with a Retry button (writes are never retried automatically). Tailux soft error alert. */
export function RetryAlert({ message, onRetry, busy = false, testId = 'retry-alert' }: { message: string; onRetry: () => void; busy?: boolean; testId?: string }) {
  return (
    <div
      role="alert"
      data-testid={testId}
      className="this:error flex flex-wrap items-center justify-between gap-3 rounded-lg bg-this-darker/10 px-4 py-3 text-this-darker dark:bg-this-lighter/10 dark:text-this-lighter sm:px-5"
    >
      <span>{message}</span>
      <Button variant="secondary" className="px-3 py-1" disabled={busy} onClick={onRetry}>
        {busy ? 'Retrying…' : 'Retry'}
      </Button>
    </div>
  )
}
