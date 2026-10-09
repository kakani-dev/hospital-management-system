import { afterEach, describe, expect, it, vi } from 'vitest'
import { localToday } from './dates'
import { createPatientSchema, patientSchema } from '../features/patients/patientSchema'

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

  it('uses the branch zone, not the workstation zone: New York workstation, Kolkata branch', () => {
    env.TZ = 'America/New_York' // workstation date is still 2026-10-06
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(AFTER_IST_MIDNIGHT)
    const branchSchema = createPatientSchema(() => 'Asia/Kolkata')
    expect(branchSchema.safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(true)
    expect(branchSchema.safeParse({ ...valid, dateOfBirth: '2026-10-08' }).success).toBe(false)
    // the workstation-zone schema would have wrongly rejected the newborn the API accepts
    expect(patientSchema.safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(false)
  })

  it('uses the branch zone, not the workstation zone: Kolkata workstation, New York branch', () => {
    env.TZ = 'Asia/Kolkata' // workstation date is already 2026-10-07
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(AFTER_IST_MIDNIGHT)
    const branchSchema = createPatientSchema(() => 'America/New_York')
    expect(branchSchema.safeParse({ ...valid, dateOfBirth: '2026-10-06' }).success).toBe(true)
    // tomorrow at the branch: the API would 400, so the form must reject it too
    expect(branchSchema.safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(false)
    expect(patientSchema.safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(true)
  })

  it('falls back to the workstation zone while the branch zone is unknown', () => {
    env.TZ = 'Asia/Kolkata'
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(AFTER_IST_MIDNIGHT)
    expect(createPatientSchema(() => undefined).safeParse({ ...valid, dateOfBirth: '2026-10-07' }).success).toBe(true)
  })
})

describe('calendar helpers', () => {
  it('adds days across month and year ends', async () => {
    const { addDays } = await import('./dates')
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01')
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28')
  })

  it('weeks start on Monday', async () => {
    const { startOfWeek, weekDates } = await import('./dates')
    expect(startOfWeek('2026-10-09')).toBe('2026-10-05') // Friday -> Monday
    expect(startOfWeek('2026-10-11')).toBe('2026-10-05') // Sunday belongs to the week before
    expect(weekDates('2026-10-05')).toEqual(['2026-10-05', '2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09', '2026-10-10', '2026-10-11'])
  })

  it('formats instants in the branch time zone', async () => {
    const { dateInZone, formatTime } = await import('./dates')
    expect(formatTime('2026-10-09T03:30:00Z', 'Asia/Kolkata')).toBe('09:00')
    expect(dateInZone('2026-10-08T19:00:00Z', 'Asia/Kolkata')).toBe('2026-10-09')
    expect(dateInZone('2026-10-08T19:00:00Z', 'UTC')).toBe('2026-10-08')
  })

  it('validates calendar dates', async () => {
    const { isCalendarDate, formatDayLabel } = await import('./dates')
    expect(isCalendarDate('2026-02-29')).toBe(false)
    expect(isCalendarDate('2028-02-29')).toBe(true)
    expect(isCalendarDate('9 Oct')).toBe(false)
    expect(formatDayLabel('2026-10-09')).toMatch(/Fri.*9.*Oct/)
  })
})

describe('zone conversion', () => {
  it('maps branch-local wall-clock times to UTC instants (incl. DST zones)', async () => {
    const { zonedTimeToInstant, isoWeekday } = await import('./dates')
    expect(zonedTimeToInstant('2026-10-09', '00:00', 'Asia/Kolkata')).toBe('2026-10-08T18:30:00.000Z')
    expect(zonedTimeToInstant('2026-10-09', '09:15', 'Asia/Kolkata')).toBe('2026-10-09T03:45:00.000Z')
    expect(zonedTimeToInstant('2026-07-01', '00:00', 'America/New_York')).toBe('2026-07-01T04:00:00.000Z')
    expect(zonedTimeToInstant('2026-12-01', '00:00', 'America/New_York')).toBe('2026-12-01T05:00:00.000Z')
    expect(isoWeekday('2026-10-05')).toBe(1)
    expect(isoWeekday('2026-10-11')).toBe(7)
  })
})
