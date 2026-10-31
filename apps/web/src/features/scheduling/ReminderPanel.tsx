import { useState } from 'react'
import { useAppointmentReminders, useSetReminderOptOut } from '../../lib/api/hooks'
import type { ReminderLog } from '../../lib/api/types'

const KIND: Record<ReminderLog['kind'], string> = { lead: 'Day-before', same_day: 'Same-day' }

/** #59: inline reminder history + one-click opt-out/in for the appointment's patient. No extra screen. */
export function ReminderPanel({ appointmentId, canEdit }: { appointmentId: string; canEdit: boolean }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="mt-1" data-testid="reminder-panel">
      <button
        type="button"
        className="text-xs text-primary-600 underline dark:text-primary-400"
        aria-expanded={open}
        data-testid="reminder-toggle"
        onClick={() => setOpen((v) => !v)}
      >
        {open ? 'Hide reminders' : 'Reminders'}
      </button>
      {open && <ReminderDetails appointmentId={appointmentId} canEdit={canEdit} />}
    </div>
  )
}

function ReminderDetails({ appointmentId, canEdit }: { appointmentId: string; canEdit: boolean }) {
  const q = useAppointmentReminders(appointmentId)
  const toggle = useSetReminderOptOut(appointmentId)
  const [error, setError] = useState<string | null>(null)
  if (q.isLoading) return <p className="text-xs text-gray-600 dark:text-dark-200">Loading reminders…</p>
  if (!q.data) return <p className="text-xs text-error-darker dark:text-error-lighter">Reminders are unavailable.</p>
  const d = q.data
  return (
    <div className="mt-1 space-y-1 rounded bg-gray-50 p-2 text-xs dark:bg-dark-700" data-testid="reminder-details">
      {d.reminders.length === 0 ? (
        <p data-testid="reminder-empty">No reminder yet.</p>
      ) : (
        <ul className="space-y-0.5">
          {d.reminders.map((r) => (
            <li key={r.id} data-testid="reminder-row" data-status={r.status}>
              {KIND[r.kind]} · {r.channel === 'none' ? 'no contact' : r.channel} · <strong>{r.status}</strong>
              {r.recipientMasked ? ` · ${r.recipientMasked}` : ''}
              {r.detail ? ` — ${r.detail}` : ''}
            </li>
          ))}
        </ul>
      )}
      <label className="flex items-center gap-1">
        <input
          type="checkbox"
          data-testid="reminder-opt-out"
          checked={d.optedOut}
          disabled={!canEdit || toggle.isPending}
          onChange={(e) => {
            setError(null)
            toggle.mutate({ patientId: d.patientId, optOut: e.target.checked }, { onError: () => setError('Could not update the preference.') })
          }}
        />
        Patient does not want reminders
      </label>
      {error && <p role="alert" className="text-error-darker dark:text-error-lighter">{error}</p>}
    </div>
  )
}
