import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'

/** Human message for a failed check-in / walk-in (contract §A.1, §A.6). */
export function checkInErrorMessage(error: unknown): string {
  const code = problemCode(error)
  const status = error instanceof ApiError ? error.status : 0
  if (code === 'already_checked_in') return 'This patient is already waiting or in consultation at this branch today.'
  if (code === 'invalid_state') return 'Only appointments for today (branch time) can be checked in.'
  if (code === 'invalid_transition') return 'This appointment is no longer booked (it was cancelled or already checked in).'
  if (status === 409) return 'The patient could not be checked in (already in the queue or not bookable today).'
  if (status === 403) return 'You are not allowed to check patients in at this branch.'
  if (status === 404) return 'The appointment or patient no longer exists (it may have been cancelled or deleted).'
  return Object.values(fieldErrors(error))[0] ?? 'Check-in failed. Try again.'
}
