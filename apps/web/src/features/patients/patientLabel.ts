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

export function patientOptionLabel(p: PatientSummary, today: string): string {
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


/** True when the term is exactly this patient's MRN (case-insensitive, surrounding spaces ignored). */
export function isExactMrn(p: Pick<PatientSummary, 'mrn'>, term: string): boolean {
  const t = term.trim()
  return t.length >= PATIENT_PICKER_MIN_CHARS && p.mrn.toLowerCase() === t.toLowerCase()
}

/**
 * Exact-MRN match first: when the search term is exactly a patient's MRN, that patient moves to the
 * top (the rest keep the server's order). Below the minimum length nothing changes.
 */
export function exactMrnFirst<T extends Pick<PatientSummary, 'mrn'>>(items: T[], term: string): { items: T[]; exact: T | null } {
  const index = items.findIndex((p) => isExactMrn(p, term))
  if (index < 0) return { items, exact: null }
  const exact = items[index]!
  return { items: index === 0 ? items : [exact, ...items.slice(0, index), ...items.slice(index + 1)], exact }
}
