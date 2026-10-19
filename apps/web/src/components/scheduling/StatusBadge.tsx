import { Badge, type TailuxColor } from '@tailux/components/ui'

/** Appointment / queue status as a Tailux soft Badge. */
const COLORS: Record<string, TailuxColor> = {
  booked: 'info',
  checked_in: 'warning',
  waiting: 'warning',
  in_consultation: 'secondary',
  completed: 'success',
  done: 'success',
  cancelled: 'neutral',
  no_show: 'error',
}

const LABELS: Record<string, string> = {
  booked: 'Booked',
  checked_in: 'Checked in',
  waiting: 'Waiting',
  in_consultation: 'In consultation',
  completed: 'Completed',
  done: 'Done',
  cancelled: 'Cancelled',
  no_show: 'No-show',
}

function statusLabel(status: string): string {
  return LABELS[status] ?? status
}

export function StatusBadge({ status }: { status: string }) {
  return (
    <Badge
      color={COLORS[status] ?? 'neutral'}
      variant="soft"
      className={status === 'cancelled' ? 'line-through' : undefined}
      data-status={status}
    >
      {statusLabel(status)}
    </Badge>
  )
}
