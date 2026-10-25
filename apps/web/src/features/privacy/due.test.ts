import { describe, expect, it } from 'vitest'
import { isDueSoon } from './due'

const now = new Date('2026-10-25T00:00:00Z')

describe('isDueSoon', () => {
  it('is true inside the next 10 days and false when overdue or further out', () => {
    expect(isDueSoon('2026-11-01T00:00:00Z', now)).toBe(true)
    expect(isDueSoon('2026-11-04T00:00:01Z', now)).toBe(false)
    expect(isDueSoon('2026-10-24T00:00:00Z', now)).toBe(false)
  })
})
