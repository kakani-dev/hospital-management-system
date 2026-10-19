import { BuildingOffice2Icon, ChevronDownIcon } from '@heroicons/react/24/outline'
import { useBreakpointsContext } from '../../tailux/contexts/breakpoint/context'
import { useSidebarContext } from '../../tailux/contexts/sidebar/context'
import { TenantSwitcher } from './TenantSwitcher'
import { useCurrentContext } from './useCurrentContext'

/**
 * Header side of the responsive context (demo2 pattern). From md up the full hospital/branch
 * switcher sits in the header; on phones the header keeps a compact, truncating summary that opens
 * the navigation drawer, where {@link SidebarContextSwitcher} renders the full-width selects.
 * Exactly one switcher is mounted at a time, so labels and test ids stay unique.
 */
export function HeaderContext() {
  const { smAndDown } = useBreakpointsContext()
  return smAndDown ? <CompactContextButton /> : <TenantSwitcher />
}

export function SidebarContextSwitcher() {
  const { smAndDown } = useBreakpointsContext()
  if (!smAndDown) return null
  return (
    <section aria-label="Hospital and branch" className="mx-4 mb-3 mt-2 rounded-lg border border-gray-200 p-3 dark:border-dark-500" data-testid="sidebar-context">
      <TenantSwitcher variant="stacked" />
    </section>
  )
}

function CompactContextButton() {
  const { open, isExpanded } = useSidebarContext()
  const { me, activeTenant, branches, activeBranchId } = useCurrentContext()
  const hospital = activeTenant?.name ?? (me.data?.isPlatformAdmin ? 'Platform console' : me.isPending ? 'Loading…' : 'No hospital')
  const branch = activeTenant ? (branches.find((b) => b.id === activeBranchId)?.name ?? (branches.length > 1 ? 'All my branches' : branches[0]?.name)) : undefined
  return (
    <button
      type="button"
      onClick={open}
      aria-expanded={isExpanded}
      aria-controls="primary-sidebar"
      aria-label={`Hospital ${hospital}${branch ? `, branch ${branch}` : ''}. Change hospital or branch`}
      className="flex min-w-0 max-w-full items-center gap-2 rounded-lg px-1.5 py-1 text-left outline-hidden hover:bg-gray-100 focus-visible:ring-2 focus-visible:ring-primary-500 dark:hover:bg-dark-600"
      data-testid="compact-context"
    >
      <BuildingOffice2Icon className="size-5 shrink-0 text-primary-600 dark:text-primary-400" aria-hidden="true" />
      <span className="flex min-w-0 flex-col leading-tight">
        <span className="truncate text-xs-plus font-medium text-gray-800 dark:text-dark-100">{hospital}</span>
        {branch && <span className="truncate text-xs text-gray-500 dark:text-dark-300">{branch}</span>}
      </span>
      <ChevronDownIcon className="size-4 shrink-0 text-gray-400" aria-hidden="true" />
    </button>
  )
}
