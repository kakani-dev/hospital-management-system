/**
 * UX-only role gates for Sprint 2 screens, mirroring SPRINT2-CONTRACT.md (API v1 §A.2–A.6).
 * The API and RLS enforce the real rules; a hidden button is a convenience, never a control.
 * Writes need the role *at the row's branch* — pass the roles held at that branch
 * (rolesAtBranch) for write capabilities; tenant_admin is tenant-wide.
 */
export type Capability =
  | 'patients.view'
  | 'patients.write'
  | 'patients.delete'
  | 'patients.restore'
  | 'schedules.view'
  | 'appointments.view'
  | 'appointments.book'
  | 'queue.checkIn'
  | 'queue.view'
  | 'queue.advance'
  | 'queue.cancel'

const REG_READ = ['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'] as const
const REG_WRITE = ['tenant_admin', 'doctor', 'nurse', 'receptionist'] as const
const FRONT_DESK = ['tenant_admin', 'receptionist', 'nurse'] as const
const ANY_MEMBER = ['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing', 'pharmacist', 'lab_technician', 'viewer'] as const

const CAPABILITIES: Record<Capability, readonly string[]> = {
  'patients.view': REG_READ,
  'patients.write': REG_WRITE,
  'patients.delete': ['tenant_admin', 'receptionist'], // D1
  'patients.restore': ['tenant_admin'],
  'schedules.view': ANY_MEMBER,
  'appointments.view': REG_READ,
  'appointments.book': REG_WRITE,
  'queue.checkIn': FRONT_DESK,
  'queue.view': REG_READ,
  'queue.advance': [...FRONT_DESK, 'doctor'], // in_consultation / done
  'queue.cancel': FRONT_DESK,
}

export function can(roles: readonly string[], capability: Capability): boolean {
  return roles.some((r) => CAPABILITIES[capability].includes(r))
}

export function rolesFor(capability: Capability): readonly string[] {
  return CAPABILITIES[capability]
}
