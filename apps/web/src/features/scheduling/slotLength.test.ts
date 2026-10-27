import { describe, expect, it } from 'vitest'
import { slotLengthFor } from './slotLength'

const types = [{ id: 'a', effectiveDurationMinutes: 15 }, { id: 'b', effectiveDurationMinutes: 45 }]

describe('slotLengthFor', () => {
  it('uses the chosen visit type length', () => expect(slotLengthFor(types, 'a')).toBe(15))
  it('falls back to the longest type when none is chosen', () => expect(slotLengthFor(types, null)).toBe(45))
  it('falls back to the longest type for an unknown id', () => expect(slotLengthFor(types, 'zz')).toBe(45))
  it('is undefined without visit types', () => expect(slotLengthFor([], null)).toBeUndefined())
})
