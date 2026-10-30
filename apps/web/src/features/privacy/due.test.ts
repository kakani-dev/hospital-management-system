import { describe, expect, it } from 'vitest'
import { isDueSoon, isOverdue } from './due'

const now = new Date('2026-10-25T00:00:00Z')

describe('isDueSoon', () => {
  it('is true inside the next 10 days and false when overdue or further out', () => {
    expect(isDueSoon('2026-11-01T00:00:00Z', now)).toBe(true)
    expect(isDueSoon('2026-11-04T00:00:01Z', now)).toBe(false)
    expect(isDueSoon('2026-10-24T00:00:00Z', now)).toBe(false)
  })
})

describe('isOverdue', () => {
  const now = new Date('2026-10-30T12:00:00Z')
  it('is true once the deadline has passed', () => {
    expect(isOverdue('2026-10-30T00:00:00Z', now)).toBe(true)
  })
  it('is false while the deadline is ahead', () => {
    expect(isOverdue('2026-11-02T00:00:00Z', now)).toBe(false)
  })
  it('is false for an unparseable date', () => {
    expect(isOverdue('not a date', now)).toBe(false)
  })
})
