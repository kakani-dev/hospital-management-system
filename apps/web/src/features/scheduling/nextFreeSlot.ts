import type { Slot } from '../../lib/api/types'

/** The next slot that has not started, else the first one offered. */
export function nextFreeSlot(slots: readonly Slot[], now = Date.now()): Slot | null {
  return slots.find((s) => Date.parse(s.startsAt) > now) ?? slots[0] ?? null
}
