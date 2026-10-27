import { useState } from 'react'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { FormField } from '../../components/ui/FormField'
import { ApiError } from '../../lib/api/client'
import type { Vitals } from '../../lib/api/types'
import { usePatientVitals, useRecordVitals, useVisitVitals, vitalsErrorMessage } from './vitalsApi'
import { emptyVitals, flagText, toVitalsRequest, validateVitals, type VitalsForm, type VitalsFormKey } from './vitalsModel'

const FIELDS: { key: Exclude<VitalsFormKey, 'note'>; label: string; hint: string; step: string }[] = [
  { key: 'systolic', label: 'BP systolic', hint: 'mmHg', step: '1' },
  { key: 'diastolic', label: 'BP diastolic', hint: 'mmHg', step: '1' },
  { key: 'pulse', label: 'Pulse', hint: 'per minute', step: '1' },
  { key: 'temperatureC', label: 'Temperature', hint: '°C', step: '0.1' },
  { key: 'spo2', label: 'SpO2', hint: '%', step: '1' },
  { key: 'respRate', label: 'Respiratory rate', hint: 'per minute', step: '1' },
  { key: 'weightKg', label: 'Weight', hint: 'kg', step: '0.1' },
  { key: 'heightCm', label: 'Height', hint: 'cm', step: '0.1' },
]

const testId = (k: string) => `clinical-vitals-${k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`

/** One reading as a compact line; out-of-range values are flagged (stored as entered). */
export function VitalsReading({ v }: { v: Vitals }) {
  const parts = [
    v.systolic != null && `BP ${v.systolic}/${v.diastolic}`,
    v.pulse != null && `Pulse ${v.pulse}`,
    v.temperatureC != null && `Temp ${v.temperatureC} °C`,
    v.spo2 != null && `SpO2 ${v.spo2}%`,
    v.respRate != null && `RR ${v.respRate}`,
    v.weightKg != null && `Wt ${v.weightKg} kg`,
    v.heightCm != null && `Ht ${v.heightCm} cm`,
    v.bmi != null && `BMI ${v.bmi}`,
  ].filter(Boolean)
  return (
    <div className="text-sm" data-testid="vitals-reading">
      <span className="text-gray-500 dark:text-dark-300">{new Date(v.recordedOn).toLocaleString()}</span> · {parts.join(' · ')}
      {v.note && <span className="text-gray-600 dark:text-dark-200"> · {v.note}</span>}
      {v.flags.length > 0 && (
        <ul className="mt-1 flex flex-wrap gap-1" data-testid="vitals-flags" aria-label="Out-of-range values">
          {v.flags.map((f) => (
            <li
              key={f.field}
              data-testid={`vitals-flag-${f.field}`}
              className={`rounded px-1.5 py-0.5 text-xs font-semibold ${f.level === 'critical' ? 'bg-error/15 text-error-darker' : 'bg-warning/15 text-warning-darker'}`}
            >
              {flagText(f)}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

/** Vitals for one visit: the readings so far and, for nurse/doctor, the entry form. */
export function VitalsPanel({ queueEntryId, canRecord }: { queueEntryId: string; canRecord: boolean }) {
  const list = useVisitVitals(queueEntryId)
  const record = useRecordVitals()
  const [form, setForm] = useState<VitalsForm>(emptyVitals)
  const [errors, setErrors] = useState<ReturnType<typeof validateVitals>>({})
  const [serverError, setServerError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  // One key per entry: a double click or a retry after a lost response does not create two readings.
  const [clientId, setClientId] = useState(() => crypto.randomUUID())

  const set = (k: VitalsFormKey, value: string) => {
    setForm((f) => ({ ...f, [k]: value }))
    setSaved(false)
  }

  async function submit() {
    if (record.isPending) return
    const found = validateVitals(form)
    setErrors(found)
    setServerError(null)
    if (Object.keys(found).length > 0) return
    try {
      await record.mutateAsync(toVitalsRequest(form, queueEntryId, clientId))
      setForm(emptyVitals())
      setClientId(crypto.randomUUID())
      setSaved(true)
    } catch (e) {
      setServerError(vitalsErrorMessage(e))
    }
  }

  return (
    <Card title="Vitals">
      <div className="space-y-3" data-testid="vitals-panel">
        {list.isPending && <p role="status">Loading vitals…</p>}
        {list.isError && <Alert tone="warning">{list.error instanceof ApiError && list.error.status === 403 ? 'Your role cannot view vitals.' : 'Vitals are unavailable.'}</Alert>}
        {list.data && list.data.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="vitals-empty">No vitals recorded for this visit yet.</p>}
        {list.data && list.data.length > 0 && (
          <ul className="divide-y divide-gray-200 dark:divide-dark-500" data-testid="vitals-visit-list">
            {list.data.map((v) => (
              <li key={v.id} className="py-2">
                <VitalsReading v={v} />
              </li>
            ))}
          </ul>
        )}
        {canRecord && (
          <form
            className="space-y-3"
            data-testid="vitals-form"
            noValidate
            onSubmit={(e) => {
              e.preventDefault()
              void submit()
            }}
          >
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {FIELDS.map((f) => (
                <FormField
                  key={f.key}
                  data-testid={testId(f.key)}
                  label={f.label}
                  hint={f.hint}
                  type="number"
                  inputMode="decimal"
                  step={f.step}
                  value={form[f.key]}
                  error={errors[f.key]}
                  onChange={(e) => set(f.key, e.target.value)}
                />
              ))}
            </div>
            <FormField data-testid="clinical-vitals-note" label="Note (optional)" value={form.note} error={errors.note} onChange={(e) => set('note', e.target.value)} />
            {errors.form && <Alert tone="warning">{errors.form}</Alert>}
            {serverError && <Alert tone="error">{serverError}</Alert>}
            {saved && <p role="status" className="text-sm text-success-darker" data-testid="vitals-saved">Vitals saved.</p>}
            <Button type="submit" data-testid="vitals-save" disabled={record.isPending}>
              {record.isPending ? 'Saving…' : 'Save vitals'}
            </Button>
          </form>
        )}
      </div>
    </Card>
  )
}

/** Vitals history on the patient page (clinical.view), newest first. */
export function PatientVitals({ patientId }: { patientId: string }) {
  const list = usePatientVitals(patientId)
  return (
    <Card title="Vitals history">
      <div data-testid="vitals-history">
        {list.isPending && <p role="status">Loading vitals…</p>}
        {list.isError && <Alert tone="warning">{list.error instanceof ApiError && list.error.status === 403 ? 'Your role cannot view vitals.' : 'Vitals history is unavailable.'}</Alert>}
        {list.data && list.data.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200">No vitals recorded yet.</p>}
        {list.data && list.data.length > 0 && (
          <ul className="divide-y divide-gray-200 dark:divide-dark-500">
            {list.data.map((v) => (
              <li key={v.id} className="py-2" data-testid="vitals-history-row">
                <VitalsReading v={v} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  )
}
