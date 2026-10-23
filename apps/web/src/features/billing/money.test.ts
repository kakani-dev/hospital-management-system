import { describe, expect, it } from 'vitest'
import { formatPaise, rupeesToPaise } from './money'

describe('formatPaise', () => {
  it('prints rupees from integer paise, including round-off', () => {
    expect(formatPaise(50000)).toBe('₹500.00')
    expect(formatPaise(5010)).toBe('₹50.10')
    expect(formatPaise(-10)).toBe('−₹0.10')
    expect(formatPaise(0)).toBe('₹0.00')
  })

  it('converts a rupee entry to paise', () => {
    expect(rupeesToPaise(50)).toBe(5000)
    expect(rupeesToPaise(0.1)).toBe(10)
  })
})
