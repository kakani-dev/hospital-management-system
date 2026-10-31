import { useId, useState } from 'react'
import { Link } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Card } from '../../components/ui/Card'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { apiClient } from '../../lib/api/client'
import type { RxDispenseStatus } from '../../lib/api/types'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { problemText, STATUS_LABEL, StatusBadge, AllergyNotice, ageSexText } from './pharmacyUi'

const FILTERS = [
  { value: 'open', label: 'To dispense (pending and partial)' },
  { value: 'pending', label: STATUS_LABEL.pending },
  { value: 'partial', label: STATUS_LABEL.partial },
  { value: 'dispensed', label: STATUS_LABEL.dispensed },
  { value: 'all', label: 'All' },
] as const

/** Pharmacist queue: finalized prescriptions at the active branch, oldest first (#106). */
export function PharmacyQueuePage() {
  const { activeBranchId } = useCurrentContext()
  const [status, setStatus] = useState<string>('open')
  const filterId = useId()
  const queue = useQuery({
    queryKey: ['pharmacy', 'queue', activeBranchId, status],
    queryFn: () => apiClient.pharmacy.queue({ branchId: activeBranchId ?? undefined, status }),
  })

  return (
    <div className="space-y-4" data-testid="pharmacy-queue-page">
      <h1 className="text-xl font-semibold text-gray-900 dark:text-dark-50">Prescriptions to dispense</h1>
      <Card title="Queue">
        <label htmlFor={filterId} className="mb-3 block max-w-xs text-sm font-medium text-gray-800 dark:text-dark-100">
          Show
          <select
            id={filterId}
            data-testid="pharmacy-queue-filter"
            className="mt-1 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700"
            value={status}
            onChange={(e) => setStatus(e.target.value)}
          >
            {FILTERS.map((f) => (
              <option key={f.value} value={f.value}>{f.label}</option>
            ))}
          </select>
        </label>
        {queue.isPending ? (
          <LoadingBlock />
        ) : queue.isError ? (
          <Alert tone="error">{problemText(queue.error)}</Alert>
        ) : queue.data.length === 0 ? (
          <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="pharmacy-queue-empty">No prescriptions waiting.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm" data-testid="pharmacy-queue-table">
              <thead>
                <tr className="border-b border-gray-200 dark:border-dark-500">
                  <th className="py-2 pr-3">Finalized</th>
                  <th className="py-2 pr-3">Patient</th>
                  <th className="py-2 pr-3">Doctor</th>
                  <th className="py-2 pr-3">Valid through</th>
                  <th className="py-2 pr-3">Medicines</th>
                  <th className="py-2 pr-3">Status</th>
                  <th className="py-2"><span className="sr-only">Open</span></th>
                </tr>
              </thead>
              <tbody>
                {queue.data.map((row) => (
                  <tr key={row.id} className="border-b border-gray-100 dark:border-dark-600" data-testid="pharmacy-queue-row" data-status={row.status}>
                    <td className="py-2 pr-3">{new Date(row.finalizedOn).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}</td>
                    <td className="py-2 pr-3">
                      {row.patientName} <span className="text-gray-500">({row.patientMrn})</span>
                      {ageSexText(row) && <span className="block text-xs text-gray-600 dark:text-dark-200">{ageSexText(row)}</span>}
                      <span className="block text-xs"><AllergyNotice patient={row} compact /></span>
                    </td>
                    <td className="py-2 pr-3">{row.doctorName}</td>
                    <td className="py-2 pr-3" data-testid="pharmacy-queue-valid-through" data-expired={row.expired ? 'true' : 'false'}>
                      {row.validThrough
                        ? `${new Date(`${row.validThrough}T00:00:00`).toLocaleDateString('en-IN', { dateStyle: 'medium' })}${row.expired ? ' (expired)' : ''}`
                        : '—'}
                    </td>
                    <td className="py-2 pr-3">{row.lineCount}</td>
                    <td className="py-2 pr-3"><StatusBadge status={row.status as RxDispenseStatus} /></td>
                    <td className="py-2">
                      <Link className="text-primary-600 underline dark:text-primary-400" to={`/pharmacy/dispense/${row.id}`} data-testid="pharmacy-queue-open">
                        Open
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  )
}
