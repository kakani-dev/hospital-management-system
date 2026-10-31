import type { PrescriptionLine, Vitals } from '../../lib/api/types'
import { FOOD_LABEL } from './consultationModel'

/** "Tab Paracetamol 650 mg — 1-1-1 × 5 days, after food". Empty parts are left out, never printed as "—". */
export function rxLineText(l: PrescriptionLine): string {
  const name = [l.medicineName, l.strength].filter(Boolean).join(' ')
  const dose = l.dose && !/^1( tab(let)?)?$/i.test(l.dose.trim()) ? `${l.dose} ` : ''
  const days = l.durationDays ? ` × ${l.durationDays} ${l.durationDays === 1 ? 'day' : 'days'}` : ''
  const extras = [
    l.foodTiming && l.foodTiming !== 'any' ? FOOD_LABEL[l.foodTiming].toLowerCase() : null,
    l.route && !/^oral$/i.test(l.route.trim()) ? l.route : null,
    l.instructions,
  ].filter(Boolean)
  return `${name} — ${dose}${l.frequency}${days}${extras.length ? `, ${extras.join(', ')}` : ''}`
}

/** Follow-up on paper: "Thu, 5 Nov 2026" (weekday + date), not an ISO string. */
export function followUpLabel(date: string, locale = 'en-IN'): string {
  return new Intl.DateTimeFormat(locale, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${date.slice(0, 10)}T00:00:00Z`))
}

/** "BP 128/84 · P 92/min · T 38.2 °C · SpO₂ 98% · RR 18/min · Wt 72 kg" — only recorded values. */
export function vitalsLine(v: Vitals): string | null {
  const parts = [
    v.systolic != null && v.diastolic != null ? `BP ${v.systolic}/${v.diastolic}` : null,
    v.pulse != null ? `P ${v.pulse}/min` : null,
    v.temperatureC != null ? `T ${v.temperatureC} °C` : null,
    v.spo2 != null ? `SpO₂ ${v.spo2}%` : null,
    v.respRate != null ? `RR ${v.respRate}/min` : null,
    v.weightKg != null ? `Wt ${v.weightKg} kg` : null,
    v.heightCm != null ? `Ht ${v.heightCm} cm` : null,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : null
}
