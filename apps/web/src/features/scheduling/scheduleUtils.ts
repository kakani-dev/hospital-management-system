import { dateInZone, isoWeekday, localToday, zonedTimeToInstant } from '../../lib/dates'
import type { Practitioner, Schedule, Slot } from '../../lib/api/types'

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

/** Why a day's slot query came back empty. */
export type EmptyDayReason = 'no_schedule' | 'day_over' | 'fully_booked'

const EMPTY_DAY_TEXT: Record<EmptyDayReason, string> = {
  no_schedule: 'This doctor has no working hours on this day.',
  day_over: "This day's working hours are over.",
  fully_booked: 'Every slot on this day is booked.',
}

export function emptyDayText(reason: EmptyDayReason): string {
  return EMPTY_DAY_TEXT[reason]
}

/**
 * no_schedule: no working-hours block that day.
 * day_over: the date is today or earlier and the last slot start (block end minus slot length) is not still ahead.
 * fully_booked: a block still has a slot start ahead of now, but none of those slots are free.
 */
export function explainEmptyDay(schedules: readonly Schedule[], date: string, practitionerId: string, now: Date, timeZone: string): EmptyDayReason {
  const blocks = schedulesOn(schedules, date, practitionerId)
  if (blocks.length === 0) return 'no_schedule'
  const today = localToday(now, timeZone)
  if (date > today) return 'fully_booked'
  let lastStart = Number.NEGATIVE_INFINITY
  for (const block of blocks) {
    const end = Date.parse(zonedTimeToInstant(date, hhmm(block.endTime), timeZone))
    const start = end - block.slotMinutes * 60_000
    if (start > lastStart) lastStart = start
  }
  return lastStart > now.getTime() ? 'fully_booked' : 'day_over'
}

/** Earliest branch-local date that still has a free slot. */
export function nextFreeDate(slots: readonly Slot[], timeZone: string): string | null {
  const dates = [...new Set(slots.map((s) => dateInZone(s.startsAt, timeZone)))].sort()
  return dates[0] ?? null
}
