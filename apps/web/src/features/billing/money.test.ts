import { describe, expect, it } from 'vitest'
import { formatPaise, parseRupeesToPaise, rupeesToPaise } from './money'

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

describe('parseRupeesToPaise', () => {
  it('accepts rupees a cashier would type and stores paise', () => {
    expect(parseRupeesToPaise('150')).toBe(15000)
    expect(parseRupeesToPaise('150.5')).toBe(15050)
    expect(parseRupeesToPaise('₹1,500.50')).toBe(150050)
    expect(parseRupeesToPaise('0')).toBe(0)
    expect(parseRupeesToPaise('10.555')).toBeNull()
    expect(parseRupeesToPaise('-1')).toBeNull()
    expect(parseRupeesToPaise('')).toBeNull()
  })
})
