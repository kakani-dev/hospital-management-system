import { describe, expect, it } from 'vitest'
import { can } from './permissions'
import { rolesAtBranch } from '../features/tenancy/useCurrentContext'
import { meFor, ALPHA, ALPHA_EAST, ALPHA_MAIN } from '../test/fakes'

describe('can', () => {
  it('gates Sprint 2 capabilities by role (contract §A.2)', () => {
    expect(can(['receptionist'], 'appointments.book')).toBe(true)
    expect(can(['doctor'], 'appointments.book')).toBe(true)
    expect(can(['billing'], 'appointments.book')).toBe(false)
    expect(can(['billing'], 'appointments.view')).toBe(true)
    expect(can(['receptionist'], 'queue.checkIn')).toBe(true)
    expect(can(['doctor'], 'queue.checkIn')).toBe(false)
    expect(can(['doctor'], 'queue.advance')).toBe(true)
    expect(can(['doctor'], 'queue.cancel')).toBe(false)
    expect(can(['receptionist'], 'patients.delete')).toBe(true)
    expect(can(['nurse'], 'patients.delete')).toBe(false)
    expect(can(['receptionist'], 'patients.restore')).toBe(false)
    expect(can(['viewer'], 'schedules.view')).toBe(true)
    expect(can(['viewer', 'pharmacist'], 'queue.view')).toBe(false)
    expect(can([], 'schedules.view')).toBe(false)
  })
})

describe('rolesAtBranch', () => {
  it('counts tenant-wide memberships everywhere and branch memberships only at their branch', () => {
    const me = meFor({
      roles: ['receptionist', 'doctor'],
      memberships: [
        { tenantId: ALPHA, tenantName: 'A', branchId: ALPHA_MAIN, branchName: null, role: 'receptionist' },
        { tenantId: ALPHA, tenantName: 'A', branchId: null, branchName: null, role: 'doctor' },
        { tenantId: 'other', tenantName: 'B', branchId: null, branchName: null, role: 'tenant_admin' },
      ],
    })
    expect(rolesAtBranch(me, ALPHA_MAIN).sort()).toEqual(['doctor', 'receptionist'])
    expect(rolesAtBranch(me, ALPHA_EAST)).toEqual(['doctor'])
    expect(rolesAtBranch(undefined, ALPHA_MAIN)).toEqual([])
  })
})
