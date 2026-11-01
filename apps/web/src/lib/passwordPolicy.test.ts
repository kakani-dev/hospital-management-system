import { describe, expect, it } from 'vitest'
import { generatePassword, isStrongEnough } from './passwordPolicy'

describe('passwordPolicy', () => {
  it('rejects short, letter-only and digit-only passwords', () => {
    expect(isStrongEnough('abc12')).toBe(false)
    expect(isStrongEnough('onlyletterspassword')).toBe(false)
    expect(isStrongEnough('12345678901234')).toBe(false)
    expect(isStrongEnough('x'.repeat(80) + '1')).toBe(false)
    expect(isStrongEnough('Synthetic1234')).toBe(true)
  })

  it('generates different passwords that always meet the policy', () => {
    const all = Array.from({ length: 50 }, () => generatePassword())
    expect(all.every(isStrongEnough)).toBe(true)
    expect(new Set(all).size).toBe(50)
  })
})
