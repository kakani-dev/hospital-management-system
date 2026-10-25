/**
 * RBAC (docs/adr/0001-role-based-access-control.md). UX-only gates: the API (permission checks on
 * server-side membership) and RLS enforce the real rules; a hidden button is a convenience, never
 * a control.
 *
 * ROLE_PERMISSIONS mirrors HmsPermissions.ByRole in the API and identity.role_permissions in the
 * database (RbacMatrixInProcessTests in the .NET suite compares all three). Tenant-wide gates (menus, routes)
 * prefer the server's own list, GET /me `permissions`; branch-bound writes pass the roles held AT
 * the row's branch (rolesAtBranch) to `can`.
 */
export type Permission =
  | 'settings.view'
  | 'settings.manage'
  | 'branches.view'
  | 'branches.manage'
  | 'members.manage'
  | 'practitioners.view'
  | 'practitioners.manage'
  | 'patients.view'
  | 'patients.create'
  | 'patients.edit'
  | 'patients.delete'
  | 'patients.restore'
  | 'appointments.view'
  | 'appointments.book'
  | 'appointments.reschedule'
  | 'appointments.cancel'
  | 'appointments.check_in'
  | 'appointments.no_show'
  | 'appointments.no_show_own'
  | 'appointments.book_followup_own'
  | 'appointments.override_hours'
  | 'queue.view'
  | 'queue.manage'
  | 'queue.consult_own'
  | 'billing.view'
  | 'billing.bill'
  | 'billing.collect'
  | 'billing.discount_request'
  | 'billing.approve'
  | 'billing.refund'
  | 'billing.counter_reconcile'
  | 'billing.pricelist_manage'
  | 'inventory.view'
  | 'inventory.catalog'
  | 'inventory.opening'
  | 'inventory.approve'
  | 'privacy.view'
  | 'privacy.consent'
  | 'privacy.notice'
  | 'privacy.request'
  | 'privacy.fulfil'
  | 'privacy.erase'

/** UI capabilities (kept stable for the screens) -> the server permissions that grant them (any of). */
const CAPABILITIES = {
  'patients.view': ['patients.view'],
  'patients.write': ['patients.create'],
  'patients.edit': ['patients.edit'],
  'patients.delete': ['patients.delete'],
  'patients.restore': ['patients.restore'],
  'schedules.view': ['practitioners.view'],
  'appointments.view': ['appointments.view'],
  'appointments.book': ['appointments.book'],
  /** Follow-up of an earlier visit: any booker, or any clinician who may book follow-ups at this branch. */
  'appointments.bookFollowUp': ['appointments.book', 'appointments.book_followup_own'],
  /** Book outside the doctor's working hours (admins; audited). */
  'appointments.overrideHours': ['appointments.override_hours'],
  'appointments.reschedule': ['appointments.reschedule'],
  'appointments.cancel': ['appointments.cancel'],
  'appointments.noShow': ['appointments.no_show', 'appointments.no_show_own'],
  'queue.checkIn': ['queue.manage'],
  'queue.view': ['queue.view'],
  'queue.advance': ['queue.manage', 'queue.consult_own'],
  'queue.cancel': ['queue.manage'],
  'billing.view': ['billing.view'],
  'billing.bill': ['billing.bill'],
  'billing.collect': ['billing.collect'],
  'billing.discount': ['billing.discount_request'],
  'billing.approve': ['billing.approve'],
  'billing.reconcile': ['billing.counter_reconcile'],
  'admin.branches': ['branches.manage'],
  'admin.members': ['members.manage'],
  'admin.practitioners': ['practitioners.manage'],
  'admin.settings': ['settings.manage'],
  'admin.pricelist': ['billing.pricelist_manage'],
  'stock.view': ['inventory.view'],
  'stock.edit': ['inventory.catalog'],
  'stock.open': ['inventory.opening'],
  'stock.approve': ['inventory.approve'],
  'privacy.view': ['privacy.view'],
  'privacy.consent': ['privacy.consent'],
  'privacy.notice': ['privacy.notice'],
  'privacy.request': ['privacy.request'],
  'privacy.fulfil': ['privacy.fulfil'],
  'privacy.erase': ['privacy.erase'],
  'privacy.desk': ['privacy.request', 'privacy.fulfil', 'privacy.erase'],
} as const satisfies Record<string, readonly Permission[]>

export type Capability = keyof typeof CAPABILITIES

const READ_ONLY_OPS: Permission[] = ['settings.view', 'branches.view', 'practitioners.view']

export const ROLE_PERMISSIONS: Record<string, readonly Permission[]> = {
  tenant_admin: [
    ...READ_ONLY_OPS, 'settings.manage', 'branches.manage', 'members.manage', 'practitioners.manage',
    'patients.view', 'patients.create', 'patients.edit', 'patients.delete', 'patients.restore',
    'appointments.view', 'appointments.book', 'appointments.reschedule', 'appointments.cancel', 'appointments.check_in', 'appointments.no_show',
    'appointments.override_hours', 'queue.view', 'queue.manage',
    'billing.view', 'billing.bill', 'billing.collect', 'billing.discount_request', 'billing.approve', 'billing.refund', 'billing.counter_reconcile', 'billing.pricelist_manage',
    'inventory.view', 'inventory.catalog', 'inventory.opening', 'inventory.approve',
    'privacy.view', 'privacy.consent', 'privacy.notice', 'privacy.request', 'privacy.fulfil', 'privacy.erase',
  ],
  receptionist: [
    ...READ_ONLY_OPS, 'patients.view', 'patients.create', 'patients.edit', 'patients.delete',
    'appointments.view', 'appointments.book', 'appointments.reschedule', 'appointments.cancel', 'appointments.check_in', 'appointments.no_show',
    'queue.view', 'queue.manage',
    'billing.view', 'billing.bill', 'billing.collect', 'billing.discount_request',
    'privacy.view', 'privacy.consent', 'privacy.request',
  ],
  nurse: [...READ_ONLY_OPS, 'patients.view', 'appointments.view', 'appointments.book', 'appointments.check_in', 'appointments.no_show', 'queue.view', 'queue.manage'],
  doctor: [...READ_ONLY_OPS, 'patients.view', 'appointments.view', 'appointments.book_followup_own', 'appointments.no_show_own', 'queue.view', 'queue.consult_own', 'privacy.view'],
  billing: [...READ_ONLY_OPS, 'patients.view', 'appointments.view', 'billing.view', 'billing.bill', 'billing.collect', 'billing.discount_request', 'billing.refund'],
  pharmacist: [...READ_ONLY_OPS, 'inventory.view'],
  lab_technician: READ_ONLY_OPS,
  viewer: READ_ONLY_OPS,
}

export function permissionsOf(roles: readonly string[]): Set<Permission> {
  return new Set(roles.flatMap((r) => ROLE_PERMISSIONS[r] ?? []))
}

/** Capability from roles (use rolesAtBranch(...) for branch-bound writes). */
export function can(roles: readonly string[], capability: Capability): boolean {
  const granted = permissionsOf(roles)
  return CAPABILITIES[capability].some((p) => granted.has(p))
}

/** Capability from the server's effective permission list (GET /me `permissions`). */
export function allows(permissions: readonly string[], capability: Capability): boolean {
  return CAPABILITIES[capability].some((p) => permissions.includes(p))
}

export function rolesFor(capability: Capability): readonly string[] {
  return Object.keys(ROLE_PERMISSIONS).filter((r) => can([r], capability))
}
