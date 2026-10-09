const STYLES: Record<string, string> = {
  booked: 'bg-sky-100 text-sky-900',
  checked_in: 'bg-amber-100 text-amber-900',
  waiting: 'bg-amber-100 text-amber-900',
  in_consultation: 'bg-violet-100 text-violet-900',
  completed: 'bg-emerald-100 text-emerald-900',
  done: 'bg-emerald-100 text-emerald-900',
  cancelled: 'bg-slate-200 text-slate-700 line-through',
  no_show: 'bg-red-100 text-red-900',
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
    <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${STYLES[status] ?? 'bg-slate-100 text-slate-800'}`} data-status={status}>
      {statusLabel(status)}
    </span>
  )
}
