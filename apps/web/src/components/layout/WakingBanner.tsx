import { useQueryClient } from '@tanstack/react-query'
import { Button } from '../ui/Button'
import { retryPendingNow } from '../../lib/api/pending'
import { useWakingPhase } from '../../lib/api/useWakingPhase'

/**
 * Free hosting scales the edge and services to zero: the first request after a quiet spell can take
 * tens of seconds. Instead of a frozen "Loading…", say what is happening and offer "Retry now".
 * Thresholds: VITE_WAKING_BANNER_AFTER_MS / VITE_WAKING_STILL_AFTER_MS (lib/config.ts).
 */
export function WakingBanner({ afterMs, stillAfterMs }: { afterMs?: number; stillAfterMs?: number }) {
  const phase = useWakingPhase({ afterMs, stillAfterMs })
  const queryClient = useQueryClient()
  return (
    // The live region is always mounted so screen readers announce the text when it appears.
    <div role="status" aria-live="polite" className="pointer-events-none fixed inset-x-0 bottom-4 z-40 flex justify-center px-4">
      {phase !== 'idle' && (
        <div
          data-testid="waking-banner"
          data-phase={phase}
          className="pointer-events-auto flex max-w-xl flex-wrap items-center gap-3 rounded-md border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-950 shadow-lg"
        >
          <span aria-hidden="true" className="inline-block h-3 w-3 animate-pulse rounded-full bg-amber-500" />
          {phase === 'waking' ? (
            <span>Waking the server… this can take up to a minute on the free plan. Your work is safe.</span>
          ) : (
            <>
              <span>Still waking the server. It is retrying automatically.</span>
              <Button
                variant="secondary"
                className="px-3 py-1"
                onClick={() => {
                  // Skip any backoff wait; re-run queries that already gave up.
                  retryPendingNow()
                  void queryClient.refetchQueries({ type: 'active', predicate: (q) => q.state.status === 'error' })
                }}
              >
                Retry now
              </Button>
            </>
          )}
        </div>
      )}
    </div>
  )
}
