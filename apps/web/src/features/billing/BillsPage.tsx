import { useState } from 'react'
import { Link } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { ApiError, apiClient } from '../../lib/api/client'
import type { BillListItem } from '../../lib/api/types'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BILL_STATUS_LABELS, UNNUMBERED_BILL, billStatusLabel } from './billStatus'
import { formatPaise } from './money'

const columns: ColumnDef<BillListItem, unknown>[] = [
  {
    header: 'Bill',
    accessorKey: 'billNo',
    cell: ({ row }) => (
      <Link className="text-primary-600 underline" to={`/billing/bills/${row.original.id}`}>
        {row.original.billNo ?? UNNUMBERED_BILL}
      </Link>
    ),
  },
  { header: 'Status', accessorKey: 'status', cell: ({ row }) => billStatusLabel(row.original.status) },
  {
    header: 'Total',
    accessorKey: 'totalPaise',
    cell: ({ row }) => formatPaise(row.original.totalPaise ?? 0),
  },
  {
    header: 'Due',
    accessorKey: 'duePaise',
    cell: ({ row }) => formatPaise(row.original.duePaise ?? 0),
  },
]

/** Existing bill list. Filters are status, branch and branch-local dates. */
export function BillsPage() {
  const { branchId } = useBranchSelection()
  const [status, setStatus] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const bills = useQuery({
    queryKey: ['billing', 'bills', status, branchId, from, to],
    queryFn: () => apiClient.billing.list({ status: status || undefined, branchId: branchId || undefined, from: from || undefined, to: to || undefined }),
    enabled: !!branchId,
  })

  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Bills</h1>
      <div className="flex flex-wrap gap-3">
        <label className="text-sm">
          Status
          <select aria-label="Bill status" className="mt-1 block rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700" value={status} onChange={(event) => setStatus(event.target.value)}>
            <option value="">Any</option>
            {Object.entries(BILL_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>{label}</option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          From
          <input type="date" aria-label="From date" className="mt-1 block rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700" value={from} onChange={(event) => setFrom(event.target.value)} />
        </label>
        <label className="text-sm">
          To
          <input type="date" aria-label="To date" className="mt-1 block rounded-lg border border-gray-300 px-2 py-2 dark:border-dark-500 dark:bg-dark-700" value={to} onChange={(event) => setTo(event.target.value)} />
        </label>
      </div>
      {bills.isError && <Alert tone="error">{bills.error instanceof ApiError ? bills.error.message : 'Could not load bills.'}</Alert>}
      <DataTable
        data={bills.data ?? []}
        columns={columns}
        caption="Bills"
        isLoading={bills.isPending}
        empty="No bills match these filters."
        emptyTestId="bills-empty"
        getRowId={(row) => row.id}
        getRowProps={() => ({ 'data-testid': 'bill-row' })}
      />
    </div>
  )
}
