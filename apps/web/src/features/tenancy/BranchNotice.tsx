import { Alert } from '../../components/ui/Alert'
import { useCurrentContext } from './useCurrentContext'

/**
 * Branch state for branch-scoped screens. Only a LOADED /me without accessible branches means "no
 * access"; while /me loads we show a placeholder, and a failed /me is explained once by
 * ContextErrorBanner (AppShell) rather than as a false "no access".
 */
export function BranchNotice({ branchId }: { branchId: string | null }) {
  const { me, branches } = useCurrentContext()
  if (me.isPending) {
    return (
      <div role="status" data-testid="branches-loading" className="space-y-2">
        <span className="sr-only">Loading your branches…</span>
        <div aria-hidden="true" className="h-4 w-64 animate-pulse rounded bg-gray-200 dark:bg-dark-600" />
      </div>
    )
  }
  if (me.isError && !me.data) return null
  if (!branchId && branches.length === 0) return <Alert tone="warning">You do not have access to any branch in this hospital.</Alert>
  return null
}
