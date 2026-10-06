import type { MembershipDto } from '../../lib/api/types'

/**
 * SYNTHETIC demo memberships used by the Sprint 0 login placeholder.
 * IDs match supabase/seed.sql. In Sprint 1 these come from GET /api/v1/me,
 * which the backend builds from identity.memberships for the authenticated user.
 */
export const DEMO_MEMBERSHIPS: MembershipDto[] = [
  {
    tenantId: '11111111-1111-4111-8111-111111111111',
    tenantName: 'Demo Alpha Hospital (synthetic)',
    branchId: 'a1111111-0000-4000-8000-000000000001',
    branchName: 'Alpha Main Campus',
    role: 'tenant_admin',
  },
  {
    tenantId: '11111111-1111-4111-8111-111111111111',
    tenantName: 'Demo Alpha Hospital (synthetic)',
    branchId: 'a1111111-0000-4000-8000-000000000002',
    branchName: 'Alpha East Clinic',
    role: 'tenant_admin',
  },
]
