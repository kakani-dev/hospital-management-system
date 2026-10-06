import { afterEach, describe, expect, it, vi } from 'vitest'
import { localToday } from './dates'
import { patientSchema } from '../features/patients/patientSchema'

// 2026-10-06T19:00:00Z is already 2026-10-07 00:30 in India (UTC+5:30): the UTC date lags a day.
const AFTER_IST_MIDNIGHT = new Date('2026-10-06T19:00:00Z')
// Node re-reads process.env.TZ at runtime, which lets one test run "in India".
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env
const originalTz = env.TZ

afterEach(() => {
  vi.useRealTimers()
  if (originalTz === undefined) delete env.TZ
  else env.TZ = originalTz
})

describe('localToday', () => {
  it('uses the local (branch) calendar date, not the UTC date', () => {
    expect(AFTER_IST_MIDNIGHT.toISOString().slice(0, 10)).toBe('2026-10-06')
    expect(localToday(AFTER_IST_MIDNIGHT, 'Asia/Kolkata')).toBe('2026-10-07')
    expect(localToday(AFTER_IST_MIDNIGHT, 'America/New_York')).toBe('2026-10-06')
  })

  it('defaults to the browser time zone', () => {
    env.TZ = 'Asia/Kolkata'
    expect(localToday(AFTER_IST_MIDNIGHT)).toBe('2026-10-07')
  })
})

describe('patientSchema date of birth (time zone edge)', () => {
  const valid = {
    mrn: 'NB-0001',
    firstName: 'Baby',
    lastName: 'Synthetic',
    sex: 'unknown' as const,
    registeredBranchId: 'a1111111-0000-4000-8000-000000000001',
    phone: '',
    email: '',
  }

  it('accepts a newborn registered at 00:30 IST (UTC date is still yesterday) and rejects tomorrow', () => {
    env.TZ = 'Asia/Kolkata'
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(AFTER_IST_MIDNIGHT)
    expect(patientSchema.safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(true)
    expect(patientSchema.safeParse({ ...valid, dateOfBirth: '2026-10-08' }).success).toBe(false)
  })
})
