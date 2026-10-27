import {
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type ColumnDef,
  type Row,
  type SortingState,
} from '@tanstack/react-table'
import clsx from 'clsx'
import { useState, type HTMLAttributes, type ReactNode } from 'react'
import { Table, TBody, THead, Td, Th, Tr } from '@tailux/components/ui'
import { TableSortIcon } from '@tailux/components/shared/table/TableSortIcon'
import { useThemeContext } from '@tailux/contexts/theme/context'

export type { ColumnDef } from '@tanstack/react-table'

/**
 * The Tailux demo datatable markup (js/demo .../tables/orders-datatable-1: Table/THead/Tr/Th/Td,
 * gray header row, bordered rows, TableSortIcon) driven by TanStack Table v8, typed. Paging is
 * server-side (see ServerPagination); sorting applies to the rows on screen. Sortable headers are
 * real buttons with aria-sort on the <th> (the template uses a clickable div).
 */
export function DataTable<T>({
  data,
  columns,
  caption,
  isLoading = false,
  isStale = false,
  isFetching = false,
  empty,
  emptyTestId,
  testId,
  getRowId,
  getRowProps,
  dense = false,
  rowHeader,
}: {
  data: T[]
  columns: ColumnDef<T, unknown>[]
  caption: string
  isLoading?: boolean
  /** Previous results kept on screen while the next query loads (dimmed). */
  isStale?: boolean
  isFetching?: boolean
  empty: ReactNode
  emptyTestId?: string
  /**
   * Stable test id base, module-screen-element (e.g. `patients-list`). The table gets `<testId>`,
   * each row `<testId>-row`, each cell `<testId>-cell-<column-id>` and the empty cell `<testId>-empty`.
   * `getRowProps` / `emptyTestId` still win when given.
   */
  testId?: string
  getRowId?: (row: T, index: number) => string
  getRowProps?: (row: Row<T>) => HTMLAttributes<HTMLTableRowElement> & { [k: `data-${string}`]: string | undefined }
  dense?: boolean
  /** Column id rendered as <th scope="row"> (row header). */
  rowHeader?: string
}) {
  const { cardSkin } = useThemeContext()
  const [sorting, setSorting] = useState<SortingState>([])

  // TanStack Table returns functions that can't be memoized; the React Compiler lint rule is
  // advisory here (this component is not compiled).
  // eslint-disable-next-line react-hooks/incompatible-library
  const table = useReactTable({
    data,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getRowId,
  })

  const colCount = table.getVisibleLeafColumns().length
  const cellBg = clsx('relative bg-white', cardSkin === 'shadow' ? 'dark:bg-dark-700' : 'dark:bg-dark-900')

  return (
    <div className="table-wrapper relative min-w-full overflow-x-auto" data-testid={testId}>
      <Table hoverable dense={dense} className="w-full text-left rtl:text-right">
        <caption className="sr-only">{caption}</caption>
        <THead>
          {table.getHeaderGroups().map((headerGroup) => (
            <Tr key={headerGroup.id}>
              {headerGroup.headers.map((header) => {
                const sorted = header.column.getIsSorted()
                const label = header.isPlaceholder ? null : flexRender(header.column.columnDef.header, header.getContext())
                return (
                  <Th
                    key={header.id}
                    scope="col"
                    aria-sort={sorted === 'asc' ? 'ascending' : sorted === 'desc' ? 'descending' : undefined}
                    className="bg-gray-200 font-semibold uppercase text-gray-800 dark:bg-dark-800 dark:text-dark-100 first:ltr:rounded-tl-lg last:ltr:rounded-tr-lg first:rtl:rounded-tr-lg last:rtl:rounded-tl-lg"
                  >
                    {header.column.getCanSort() ? (
                      <button
                        type="button"
                        className="flex w-full cursor-pointer select-none items-center space-x-3 text-left uppercase"
                        onClick={header.column.getToggleSortingHandler()}
                      >
                        <span className="flex-1">{label}</span>
                        <TableSortIcon sorted={sorted} />
                      </button>
                    ) : (
                      label
                    )}
                  </Th>
                )
              })}
            </Tr>
          ))}
        </THead>
        <TBody className={clsx('transition-opacity', isStale && 'opacity-60')} aria-busy={isFetching} data-stale={isStale || undefined}>
          {isLoading && (
            <Tr>
              <Td colSpan={colCount} className={clsx(cellBg, 'py-6 text-center text-gray-500 dark:text-dark-300')}>
                <span role="status">Loading…</span>
              </Td>
            </Tr>
          )}
          {table.getRowModel().rows.map((row) => {
            const { className: rowClass, ...rowProps } = getRowProps?.(row) ?? {}
            return (
              <Tr
                key={row.id}
                className={clsx('relative border-y border-transparent border-b-gray-200 dark:border-b-dark-500', rowClass)}
                data-testid={testId ? `${testId}-row` : undefined}
                {...rowProps}
              >
                {row.getVisibleCells().map((cell) => {
                  const content = flexRender(cell.column.columnDef.cell, cell.getContext())
                  const cellTestId = testId ? `${testId}-cell-${kebab(cell.column.id)}` : undefined
                  return cell.column.id === rowHeader ? (
                    <Th key={cell.id} scope="row" className={clsx(cellBg, 'font-normal normal-case')} data-testid={cellTestId}>
                      {content}
                    </Th>
                  ) : (
                    <Td key={cell.id} className={cellBg} data-testid={cellTestId}>
                      {content}
                    </Td>
                  )
                })}
              </Tr>
            )
          })}
          {!isLoading && data.length === 0 && (
            <Tr>
              <Td colSpan={colCount} className={clsx(cellBg, 'py-6 text-center text-gray-500 dark:text-dark-300')} data-testid={emptyTestId ?? (testId ? `${testId}-empty` : undefined)}>
                {empty}
              </Td>
            </Tr>
          )}
        </TBody>
      </Table>
    </div>
  )
}

/** `visitType` / `bill_no` / `Due date` → `visit-type` / `bill-no` / `due-date`. */
function kebab(id: string) {
  return id.replace(/([a-z0-9])([A-Z])/g, '$1-$2').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase()
}
