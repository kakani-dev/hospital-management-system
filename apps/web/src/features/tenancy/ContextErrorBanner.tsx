import { Button } from '../../components/ui/Button'
import { isTransientError } from '../../lib/api/client'
import { useCurrentContext } from './useCurrentContext'

/**
 * GET /me failed (after the client's own retries). Pages must not turn that into "no access to any
 * branch" or "your role cannot open this page": say what happened and offer a retry instead.
 */
export function ContextErrorBanner() {
  const { me } = useCurrentContext()
  if (!me.isError || me.data) return null
  return (
    <div role="alert" data-testid="context-error" className="this:warning bg-this-darker/10 text-this-darker dark:bg-this-lighter/10 dark:text-this-lighter border-b border-this/30 px-(--margin-x) py-3 text-sm">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3">
        <p>
          We could not load your hospital context
          {isTransientError(me.error) ? ': the server may still be waking up.' : '.'} Your session is still active.
        </p>
        <Button variant="secondary" className="px-3 py-1" disabled={me.isFetching} onClick={() => void me.refetch()}>
          {me.isFetching ? 'Retrying…' : 'Retry'}
        </Button>
      </div>
    </div>
  )
}
