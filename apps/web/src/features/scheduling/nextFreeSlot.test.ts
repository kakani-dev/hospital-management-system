import { describe, expect, it } from 'vitest'
import { nextFreeSlot } from './nextFreeSlot'

const slot = (startsAt: string) => ({ practitionerId: 'd', branchId: 'b', startsAt, endsAt: startsAt })

describe('nextFreeSlot', () => {
  const now = Date.parse('2026-10-22T10:00:00.000Z')

  it('picks the first slot that has not started', () => {
    const early = slot('2026-10-22T09:00:00.000Z')
    const next = slot('2026-10-22T10:15:00.000Z')
    const later = slot('2026-10-22T11:00:00.000Z')
    expect(nextFreeSlot([early, next, later], now)).toBe(next)
  })

  it('falls back to the first slot when every slot has started', () => {
    const only = slot('2026-10-22T09:00:00.000Z')
    expect(nextFreeSlot([only], now)).toBe(only)
  })

  it('returns null when there are no slots', () => {
    expect(nextFreeSlot([], now)).toBeNull()
  })
})
