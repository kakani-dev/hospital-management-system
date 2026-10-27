import { ApiError } from '../../lib/api/client'
import type { RxDispenseStatus } from '../../lib/api/types'

export const STATUS_LABEL: Record<RxDispenseStatus, string> = {
  pending: 'Pending',
  partial: 'Partly dispensed',
  dispensed: 'Dispensed',
}

const STATUS_CLASS: Record<RxDispenseStatus, string> = {
  pending: 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100',
  partial: 'bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-100',
  dispensed: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-100',
}

export function StatusBadge({ status }: { status: RxDispenseStatus }) {
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_CLASS[status]}`} data-testid="rx-status">
      {STATUS_LABEL[status]}
    </span>
  )
}

export function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail ?? error.message
  return 'Something went wrong. Try again.'
}
