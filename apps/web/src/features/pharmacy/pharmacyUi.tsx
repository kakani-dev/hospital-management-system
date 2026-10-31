import { ApiError } from '../../lib/api/client'
import type { PharmacyPatientSafety, RxDispenseStatus } from '../../lib/api/types'

export const STATUS_LABEL: Record<RxDispenseStatus, string> = {
  pending: 'Pending',
  partial: 'Partly dispensed',
  dispensed: 'Dispensed',
}

const STATUS_CLASS: Record<RxDispenseStatus, string> = {
  pending: 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100',
  partial: 'bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-100',
  dispensed: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-100',
}

export function StatusBadge({ status }: { status: RxDispenseStatus }) {
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_CLASS[status]}`} data-testid="rx-status">
      {STATUS_LABEL[status]}
    </span>
  )
}

export function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail ?? error.message
  return 'Something went wrong. Try again.'
}

/** "34 y · female" from the patient-safety fields; null when nothing is known. */
export function ageSexText(p: PharmacyPatientSafety): string | null {
  const parts: string[] = []
  if (p.patientAgeYears != null) parts.push(`${p.patientAgeYears} y${p.patientDobEstimated ? ' (approx.)' : ''}`)
  if (p.patientSex && p.patientSex !== 'unknown') parts.push(p.patientSex)
  return parts.length ? parts.join(' · ') : null
}

/** #275: allergies (or a clear "not recorded" warning) shown before anything is dispensed. */
export function AllergyNotice({ patient, compact = false }: { patient: PharmacyPatientSafety; compact?: boolean }) {
  const allergies = patient.patientAllergies?.trim()
  if (compact) {
    return allergies ? (
      <span className="font-medium text-red-700 dark:text-red-300" data-testid="pharmacy-allergies">Allergies: {allergies}</span>
    ) : (
      <span className="font-medium text-amber-700 dark:text-amber-300" data-testid="pharmacy-allergies-missing">Allergies not recorded</span>
    )
  }
  return allergies ? (
    <div role="alert" className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-700 dark:bg-red-950 dark:text-red-200" data-testid="pharmacy-allergies">
      <strong>Allergies:</strong> {allergies}
    </div>
  ) : (
    <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200" data-testid="pharmacy-allergies-missing">
      <strong>Allergies not recorded.</strong> Ask the patient about drug allergies before dispensing.
    </div>
  )
}
