/**
 * API contract types for the HMS gateway (/api/v1).
 * Keep in sync with backend DTOs (backend/modules/<Module>/Endpoints/*Contracts.cs).
 */

export type Guid = string

export interface HealthStatus {
  status: 'Healthy' | 'Degraded' | 'Unhealthy'
}

export interface ProblemDetails {
  type?: string
  title?: string
  status?: number
  detail?: string
  traceId?: string
  errors?: Record<string, string[]>
}

export interface PagedResult<T> {
  items: T[]
  page: number
  pageSize: number
  totalCount: number
}

export const SEXES = ['female', 'male', 'other', 'unknown'] as const
export type Sex = (typeof SEXES)[number]

export interface PatientSummary {
  id: Guid
  mrn: string
  firstName: string
  lastName: string
  dateOfBirth: string | null
  sex: Sex
  registeredBranchId: Guid
}

export interface CreatePatientRequest {
  mrn: string
  firstName: string
  lastName: string
  dateOfBirth?: string | null
  sex: Sex
  registeredBranchId: Guid
  phone?: string | null
  email?: string | null
}

export const ROLES = [
  'tenant_admin',
  'doctor',
  'nurse',
  'receptionist',
  'billing',
  'pharmacist',
  'lab_technician',
  'viewer',
] as const
export type Role = (typeof ROLES)[number]

export interface MembershipDto {
  tenantId: Guid
  tenantName: string
  branchId: Guid | null
  branchName: string | null
  role: string
}

export interface BranchOption {
  id: Guid
  name: string
}

export interface CurrentUser {
  userId: Guid
  email: string | null
  activeTenantId: Guid | null
  activeBranchId: Guid | null
  roles: string[]
  accessibleBranches: BranchOption[]
  memberships: MembershipDto[]
}

export interface SwitchContextRequest {
  tenantId: Guid
  branchId?: Guid | null
}

export interface Branch {
  id: Guid
  code: string
  name: string
  timezone: string
  isActive: boolean
}

export interface CreateBranchRequest {
  code: string
  name: string
  timezone: string
}

export interface UpdateBranchRequest {
  name?: string
  timezone?: string
  isActive?: boolean
}

export interface Member {
  id: Guid
  userId: Guid
  email: string | null
  displayName: string | null
  role: string
  branchId: Guid | null
  branchName: string | null
  status: 'active' | 'suspended' | string
}

export interface AddMemberRequest {
  email: string
  role: Role
  branchId?: Guid | null
}

/** POST /api/v1/patients/search — the search term travels in the body, never in the URL (PHI). */
export interface PatientSearchRequest {
  search: string
  page?: number
  pageSize?: number
}

export interface UpdateMemberRequest {
  role?: Role
  status?: 'active' | 'suspended'
}
