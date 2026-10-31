import { useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { ApiError } from '../../lib/api/client'
import { useReminderSettings, useUpdateReminderSettings } from '../../lib/api/hooks'
import type { ReminderSettings, UpdateReminderSettingsRequest } from '../../lib/api/types'

const kebab = (k: string) => k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)

/** #59: one compact inline card. Delivery mode is server config (test recipients only), not a UI switch. */
export function ReminderSettingsCard() {
  const q = useReminderSettings()
  if (!q.data) return null
  // Not keyed on data: the form already holds what was saved, and remounting would drop the confirmation.
  return <ReminderForm initial={q.data} />
}

function ReminderForm({ initial }: { initial: ReminderSettings }) {
  const save = useUpdateReminderSettings()
  const [v, setV] = useState<UpdateReminderSettingsRequest>({
    enabled: initial.enabled,
    leadHours: initial.leadHours,
    sameDayHours: initial.sameDayHours,
    minNoticeMinutes: initial.minNoticeMinutes,
    emailEnabled: initial.emailEnabled,
    whatsappEnabled: initial.whatsappEnabled,
    quietStart: initial.quietStart,
    quietEnd: initial.quietEnd,
  })
  const [msg, setMsg] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const num = (k: 'leadHours' | 'sameDayHours' | 'minNoticeMinutes', label: string, min: number, max: number) => (
    <label className="text-xs">
      {label}
      <input
        type="number"
        min={min}
        max={max}
        data-testid={`reminder-${kebab(k)}`}
        className="ml-1 w-16 rounded border border-gray-300 px-1 py-0.5 dark:border-dark-450 dark:bg-dark-800"
        value={v[k]}
        onChange={(e) => setV({ ...v, [k]: Number(e.target.value) })}
      />
    </label>
  )
  const check = (k: 'enabled' | 'emailEnabled' | 'whatsappEnabled', label: string, disabled = false) => (
    <label className="flex items-center gap-1 text-xs">
      <input type="checkbox" data-testid={`reminder-${kebab(k)}`} checked={v[k]} disabled={disabled} onChange={(e) => setV({ ...v, [k]: e.target.checked })} />
      {label}
    </label>
  )
  return (
    <Card title="Appointment reminders">
      <form
        noValidate
        aria-label="Appointment reminders"
        data-testid="reminder-settings"
        className="flex flex-wrap items-center gap-3"
        onSubmit={(e) => {
          e.preventDefault()
          setMsg(null)
          if (v.sameDayHours >= v.leadHours) {
            setMsg({ tone: 'error', text: 'Same-day nudge must be less than the lead time.' })
            return
          }
          save.mutate(v, {
            onSuccess: () => setMsg({ tone: 'info', text: 'Reminder settings saved.' }),
            onError: (err) =>
              setMsg({ tone: 'error', text: err instanceof ApiError && err.problem?.detail ? err.problem.detail : 'Could not save reminder settings.' }),
          })
        }}
      >
        {check('enabled', 'Send reminders')}
        {num('leadHours', 'Hours before', 1, 72)}
        {num('sameDayHours', 'Same-day nudge (h, 0 = off)', 0, 12)}
        {num('minNoticeMinutes', 'Skip if booked < min before', 0, 1440)}
        {check('emailEnabled', `Email${initial.emailAvailable ? '' : ' (not configured)'}`)}
        {check('whatsappEnabled', `WhatsApp${initial.whatsappAvailable ? '' : ' (not configured)'}`, !initial.whatsappAvailable && !v.whatsappEnabled)}
        <label className="text-xs">
          Quiet
          <input type="time" data-testid="reminder-quiet-start" className="ml-1 rounded border border-gray-300 px-1 dark:border-dark-450 dark:bg-dark-800" value={v.quietStart} onChange={(e) => setV({ ...v, quietStart: e.target.value })} />
          –
          <input type="time" data-testid="reminder-quiet-end" className="rounded border border-gray-300 px-1 dark:border-dark-450 dark:bg-dark-800" value={v.quietEnd} onChange={(e) => setV({ ...v, quietEnd: e.target.value })} />
        </label>
        <Button type="submit" variant="secondary" className="h-8" disabled={save.isPending} data-testid="reminder-save">
          Save
        </Button>
      </form>
      <p className="mt-2 text-xs text-gray-600 dark:text-dark-200" data-testid="reminder-mode">
        {initial.deliveryMode === 'TestRecipientsOnly'
          ? 'Test mode: messages go only to configured test recipients; everyone else is logged as skipped.'
          : 'Delivery is switched off on the server; settings are saved but nothing is sent.'}
      </p>
      {msg && <div className="mt-2"><Alert tone={msg.tone}>{msg.text}</Alert></div>}
    </Card>
  )
}
