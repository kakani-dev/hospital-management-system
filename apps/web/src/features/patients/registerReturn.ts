import type { PatientSummary } from '../../lib/api/types'

/**
 * "No match → Register new patient → come back with the patient selected". Everything travels in
 * router (history) state, never in the URL: the typed name is PHI.
 */
export interface RegisterReturn {
  /** Path (with ?query) to return to after registering. */
  to: string
  /** Extra state handed back on return (e.g. the booking panel's practitioner/date/slot). */
  state?: Record<string, unknown>
}

export interface RegisterPatientState {
  returnTo?: string
  returnState?: Record<string, unknown>
  prefill?: Partial<Record<'mrn' | 'firstName' | 'lastName', string>>
}

/** State present on the page we return to. */
export interface ReturnedPatientState {
  pickedPatient?: PatientSummary
  [key: string]: unknown
}

/** Best-effort split of a search term into register-form fields: MRN-like vs "First Last" / "Last, First". */
export function prefillFromTerm(term: string): RegisterPatientState['prefill'] {
  const t = term.trim()
  if (!t) return {}
  if (/\d/.test(t)) return { mrn: t.toUpperCase() }
  if (t.includes(',')) {
    const [last, ...first] = t.split(',')
    return { lastName: last!.trim(), firstName: first.join(',').trim() }
  }
  const [first, ...rest] = t.split(/\s+/)
  return { firstName: first!, lastName: rest.join(' ') }
}
