import { Pagination, PaginationItems, PaginationNext, PaginationPrevious } from '@tailux/components/ui'
import { useBreakpointsContext } from '@tailux/contexts/breakpoint/context'
import type { ReactNode } from 'react'

/**
 * Tailux PaginationSection (js/starter components/shared/table/PaginationSection.jsx) for
 * server-side paging: the page numbers and the "first–last of N entries" summary come from the API
 * page instead of a client-side table. The page size is fixed by the API call.
 */
export function ServerPagination({
  page,
  pageSize,
  totalCount,
  onPageChange,
  summary,
}: {
  page: number
  pageSize: number
  totalCount: number
  onPageChange: (page: number) => void
  /** Left-hand summary (e.g. the existing "N patients" line). */
  summary?: ReactNode
}) {
  const { isXl, is2xl } = useBreakpointsContext()
  const pageCount = Math.max(1, Math.ceil(totalCount / pageSize))
  const first = totalCount === 0 ? 0 : (page - 1) * pageSize + 1
  const last = Math.min(page * pageSize, totalCount)

  return (
    <div className="flex flex-col justify-between space-y-4 px-4 pb-4 pt-4 sm:flex-row sm:items-center sm:space-y-0 sm:px-5">
      <div className="text-xs-plus">{summary}</div>
      {pageCount > 1 && (
        <nav aria-label="Pagination">
          <Pagination
            total={pageCount}
            value={page}
            onChange={onPageChange}
            siblings={isXl ? 2 : is2xl ? 3 : 1}
            boundaries={isXl ? 2 : 1}
            getItemProps={(p) => ({ 'aria-label': `Page ${p}` })}
          >
            <PaginationPrevious aria-label="Previous page" />
            <PaginationItems />
            <PaginationNext aria-label="Next page" />
          </Pagination>
        </nav>
      )}
      <div className="truncate text-xs-plus">
        {first} - {last} of {totalCount} entries
      </div>
    </div>
  )
}
