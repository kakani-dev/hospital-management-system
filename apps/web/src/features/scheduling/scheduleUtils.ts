import { isoWeekday } from '../../lib/dates'
import type { Practitioner, Schedule } from '../../lib/api/types'

/** Active schedule blocks of a practitioner that apply on a branch-local date. */
export function schedulesOn(schedules: readonly Schedule[], date: string, practitionerId?: string): Schedule[] {
  const weekday = isoWeekday(date)
  return schedules
    .filter(
      (s) =>
        s.isActive &&
        s.weekday === weekday &&
        s.validFrom <= date &&
        (s.validTo === null || s.validTo >= date) &&
        (practitionerId === undefined || s.practitionerId === practitionerId),
    )
    .sort((a, b) => a.startTime.localeCompare(b.startTime))
}

/**
 * Practitioners bookable at a branch: those with a schedule there (practitioners are tenant-wide;
 * schedules bind them to branches). If the branch has no schedules at all, every active
 * practitioner is offered (off-schedule bookings are allowed, D5).
 */
export function practitionersAtBranch(practitioners: readonly Practitioner[], schedules: readonly Schedule[]): Practitioner[] {
  const active = practitioners.filter((p) => p.isActive)
  const scheduled = new Set(schedules.filter((s) => s.isActive).map((s) => s.practitionerId))
  if (scheduled.size === 0) return active
  return active.filter((p) => scheduled.has(p.id))
}

/** "HH:mm" from "HH:mm" or "HH:mm:ss". */
export const hhmm = (time: string) => time.slice(0, 5)
