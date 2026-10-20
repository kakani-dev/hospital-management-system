import type { PatientRef, PatientSummary } from '../../lib/api/types'
import type { BookingDraft } from './BookingPanel'

/** Statuses after which the patient was seen (or is being seen): a follow-up makes sense. */
export const FOLLOW_UP_STATUSES: readonly string[] = ['checked_in', 'in_consultation', 'completed', 'done']

/** Booking-panel initial state for a follow-up: same patient, same practitioner. */
export function followUpInitial(patient: PatientRef, practitionerId: string | null | undefined): BookingDraft & { patient: PatientSummary } {
  return {
    practitionerId: practitionerId ?? undefined,
    // Only id/mrn/name are shown by the picker; the summary fields are filled in by the server on booking.
    patient: { dateOfBirth: null, sex: 'unknown', registeredBranchId: '', ...patient } as PatientSummary,
  }
}

/** Router state the calendar page restores into an open booking panel (same shape as the register round trip). */
export function followUpRouteState(patient: PatientRef, practitionerId: string | null | undefined) {
  const { patient: picked, ...booking } = followUpInitial(patient, practitionerId)
  return { booking, pickedPatient: picked }
}
