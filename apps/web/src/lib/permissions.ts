/**
 * UX-only role gates for Sprint 2 screens (the API and RLS enforce the real rules; a hidden
 * button is a convenience, never a control). Keep in sync with SPRINT2-CONTRACT.md.
 */
export type Capability =
  | 'patients.view'
  | 'patients.write'
  | 'patients.delete'
  | 'schedules.view'
  | 'appointments.view'
  | 'appointments.book'
  | 'queue.checkIn'
  | 'queue.view'
  | 'queue.advance'

const CAPABILITIES: Record<Capability, readonly string[]> = {
  'patients.view': ['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'],
  'patients.write': ['tenant_admin', 'doctor', 'nurse', 'receptionist'],
  // Soft delete is an administrative correction (e.g. duplicate registration).
  'patients.delete': ['tenant_admin'],
  'schedules.view': ['tenant_admin', 'doctor', 'nurse', 'receptionist'],
  'appointments.view': ['tenant_admin', 'doctor', 'nurse', 'receptionist'],
  'appointments.book': ['tenant_admin', 'receptionist'],
  'queue.checkIn': ['tenant_admin', 'receptionist', 'nurse'],
  'queue.view': ['tenant_admin', 'doctor', 'nurse', 'receptionist'],
  // Calling a patient in / finishing a consult is done by clinicians.
  'queue.advance': ['tenant_admin', 'doctor', 'nurse'],
}

export function can(roles: readonly string[], capability: Capability): boolean {
  return roles.some((r) => CAPABILITIES[capability].includes(r))
}

export function rolesFor(capability: Capability): readonly string[] {
  return CAPABILITIES[capability]
}
