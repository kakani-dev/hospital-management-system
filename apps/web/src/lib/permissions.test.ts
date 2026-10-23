import { describe, expect, it } from 'vitest'
import { allows, can, ROLE_PERMISSIONS } from './permissions'
import { rolesAtBranch } from '../features/tenancy/useCurrentContext'
import { meFor, ALPHA, ALPHA_EAST, ALPHA_MAIN } from '../test/fakes'

describe('can (RBAC matrix, ADR 0001)', () => {
  it('gates capabilities by role', () => {
    expect(can(['receptionist'], 'appointments.book')).toBe(true)
    expect(can(['doctor'], 'appointments.book')).toBe(false)
    expect(can(['nurse'], 'appointments.book')).toBe(true) // business rules 2026-10-20
    // doctors: no free booking (hidden "Book appointment"), only follow-ups of their own patients
    expect(can(['doctor'], 'appointments.bookFollowUp')).toBe(true)
    expect(can(['billing'], 'appointments.bookFollowUp')).toBe(false)
    expect(can(['tenant_admin'], 'appointments.overrideHours')).toBe(true)
    expect(can(['receptionist'], 'appointments.overrideHours')).toBe(false)
    expect(can(['billing'], 'appointments.book')).toBe(false)
    expect(can(['billing'], 'appointments.view')).toBe(true)
    expect(can(['receptionist'], 'queue.checkIn')).toBe(true)
    expect(can(['nurse'], 'queue.checkIn')).toBe(true)
    expect(can(['doctor'], 'queue.checkIn')).toBe(false)
    expect(can(['doctor'], 'queue.advance')).toBe(true)
    expect(can(['doctor'], 'queue.cancel')).toBe(false)
    expect(can(['doctor'], 'patients.view')).toBe(true)
    expect(can(['doctor'], 'patients.write')).toBe(false)
    expect(can(['nurse'], 'patients.edit')).toBe(false)
    expect(can(['receptionist'], 'patients.delete')).toBe(true)
    expect(can(['nurse'], 'patients.delete')).toBe(false)
    expect(can(['receptionist'], 'patients.restore')).toBe(false)
    expect(can(['viewer'], 'schedules.view')).toBe(true)
    expect(can(['viewer', 'pharmacist', 'lab_technician'], 'patients.view')).toBe(false)
    expect(can(['viewer', 'pharmacist'], 'queue.view')).toBe(false)
    expect(can(['tenant_admin'], 'billing.approve')).toBe(true)
    expect(can(['receptionist'], 'billing.bill')).toBe(true)
    expect(can(['billing'], 'billing.collect')).toBe(true)
    expect(can(['doctor'], 'billing.bill')).toBe(false)
    expect(can(['receptionist'], 'billing.approve')).toBe(false)
    expect(can(['receptionist'], 'admin.members')).toBe(false)
    expect(can([], 'schedules.view')).toBe(false)
  })

  it('prefers the server permission list over roles', () => {
    expect(allows(['patients.view'], 'patients.view')).toBe(true)
    expect(allows(['patients.view'], 'patients.write')).toBe(false)
    expect(allows(['queue.consult_own'], 'queue.advance')).toBe(true)
  })

  it('tenant_admin holds every permission except the own-scoped variants; read-only roles see no patient data', () => {
    const all = new Set(Object.values(ROLE_PERMISSIONS).flat())
    const admin = new Set(ROLE_PERMISSIONS.tenant_admin)
    expect([...all].filter((p) => !admin.has(p)).every((p) => p.endsWith('_own'))).toBe(true)
    for (const r of ['viewer', 'pharmacist', 'lab_technician']) {
      expect(ROLE_PERMISSIONS[r]!.some((p) => p.startsWith('patients.') || p.startsWith('appointments.') || p.startsWith('queue.'))).toBe(false)
    }
  })
  // The UI matrix is compared with the API and DB matrices by RbacMatrixInProcessTests (.NET).
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
