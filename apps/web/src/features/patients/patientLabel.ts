import { localToday } from '../../lib/dates'
import type { PatientSummary } from '../../lib/api/types'

/** Searching starts at this many characters (one-letter terms match half the registry). */
export const PATIENT_PICKER_MIN_CHARS = 2

export function ageOn(dob: string | null, today: string): string | null {
  if (!dob) return null
  const [y, m, d] = dob.split('-').map(Number)
  const [ty, tm, td] = today.split('-').map(Number)
  if (!y || !m || !d || !ty || !tm || !td) return null
  const age = ty - y - (tm < m || (tm === m && td < d) ? 1 : 0)
  return age >= 0 ? `${age} y` : null
}

const maskedPhone = (phone: string | null | undefined) => {
  const digits = (phone ?? '').replace(/\D/g, '')
  return digits.length >= 4 ? `ph …${digits.slice(-4)}` : null
}

export function patientOptionLabel(p: PatientSummary, today = localToday()): string {
  const age = ageOn(p.dateOfBirth, today)
  return [
    `${p.lastName}, ${p.firstName}`,
    p.mrn,
    p.dateOfBirth ? `${p.dateOfBirth}${age ? ` (${age})` : ''}` : 'DOB unknown',
    maskedPhone(p.phone),
  ]
    .filter(Boolean)
    .join(' · ')
}

