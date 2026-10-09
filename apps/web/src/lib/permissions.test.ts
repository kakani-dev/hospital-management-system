import { describe, expect, it } from 'vitest'
import { can } from './permissions'

describe('can', () => {
  it('gates Sprint 2 capabilities by role', () => {
    expect(can(['receptionist'], 'appointments.book')).toBe(true)
    expect(can(['receptionist'], 'queue.checkIn')).toBe(true)
    expect(can(['receptionist'], 'queue.advance')).toBe(false)
    expect(can(['doctor'], 'queue.advance')).toBe(true)
    expect(can(['doctor'], 'appointments.book')).toBe(false)
    expect(can(['billing'], 'patients.view')).toBe(true)
    expect(can(['billing'], 'patients.write')).toBe(false)
    expect(can(['nurse'], 'patients.delete')).toBe(false)
    expect(can(['tenant_admin'], 'patients.delete')).toBe(true)
    expect(can(['viewer', 'pharmacist'], 'queue.view')).toBe(false)
    expect(can([], 'schedules.view')).toBe(false)
  })
})
