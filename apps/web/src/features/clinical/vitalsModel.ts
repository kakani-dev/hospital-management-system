import type { RecordVitalsRequest, VitalsFlag, VitalsField } from '../../lib/api/types'

/** Form state: raw strings so a half-typed value is never coerced. */
export interface VitalsForm {
  systolic: string
  diastolic: string
  pulse: string
  temperatureC: string
  weightKg: string
  heightCm: string
  spo2: string
  respRate: string
  note: string
}
export type VitalsFormKey = keyof VitalsForm

export const emptyVitals = (): VitalsForm => ({
  systolic: '', diastolic: '', pulse: '', temperatureC: '', weightKg: '', heightCm: '', spo2: '', respRate: '', note: '',
})

/** Hard limits (impossible values are rejected). Must match clinical.record_vitals (20261027140000). */
const LIMITS: Record<Exclude<VitalsFormKey, 'note'>, { min: number; max: number; whole: boolean; label: string }> = {
  systolic: { min: 50, max: 300, whole: true, label: 'Systolic must be 50 to 300 mmHg' },
  diastolic: { min: 20, max: 200, whole: true, label: 'Diastolic must be 20 to 200 mmHg' },
  pulse: { min: 20, max: 250, whole: true, label: 'Pulse must be 20 to 250 per minute' },
  temperatureC: { min: 30, max: 45, whole: false, label: 'Temperature must be 30 to 45 °C' },
  weightKg: { min: 0.3, max: 400, whole: false, label: 'Weight must be 0.3 to 400 kg' },
  heightCm: { min: 20, max: 250, whole: false, label: 'Height must be 20 to 250 cm' },
  spo2: { min: 0, max: 100, whole: true, label: 'SpO2 must be a whole number from 0 to 100' },
  respRate: { min: 4, max: 80, whole: true, label: 'Respiratory rate must be 4 to 80 per minute' },
}

const NUMERIC = Object.keys(LIMITS) as (keyof typeof LIMITS)[]

/** Field -> message. Empty means valid. */
export function validateVitals(f: VitalsForm): Partial<Record<VitalsFormKey | 'form', string>> {
  const errors: Partial<Record<VitalsFormKey | 'form', string>> = {}
  for (const k of NUMERIC) {
    const raw = f[k].trim()
    if (raw === '') continue
    const n = Number(raw)
    const rule = LIMITS[k]
    if (!Number.isFinite(n)) errors[k] = 'Enter a number'
    else if (n < rule.min || n > rule.max || (rule.whole && !Number.isInteger(n))) errors[k] = rule.label
  }
  const sys = f.systolic.trim()
  const dia = f.diastolic.trim()
  if ((sys === '') !== (dia === '')) errors[sys === '' ? 'systolic' : 'diastolic'] ??= 'Blood pressure needs both systolic and diastolic'
  if (sys !== '' && dia !== '' && !errors.systolic && !errors.diastolic && Number(dia) >= Number(sys)) {
    errors.diastolic = 'Diastolic must be lower than systolic'
  }
  if (f.note.length > 500) errors.note = 'Note must be at most 500 characters'
  if (NUMERIC.every((k) => f[k].trim() === '')) errors.form = 'Enter at least one vital sign'
  return errors
}

export function toVitalsRequest(f: VitalsForm, queueEntryId: string, clientId: string): RecordVitalsRequest {
  const body: RecordVitalsRequest = { queueEntryId, clientId }
  for (const k of NUMERIC) if (f[k].trim() !== '') body[k] = Number(f[k])
  if (f.note.trim() !== '') body.note = f.note.trim()
  return body
}

export const FLAG_LABEL: Record<VitalsField, string> = {
  systolic: 'Systolic BP',
  diastolic: 'Diastolic BP',
  pulse: 'Pulse',
  temperature: 'Temperature',
  spo2: 'SpO2',
  respRate: 'Respiratory rate',
}

export function flagText(f: VitalsFlag): string {
  return `${FLAG_LABEL[f.field]} ${f.level === 'critical' ? 'critically low' : f.level}`
}
