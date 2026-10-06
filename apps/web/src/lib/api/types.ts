/**
 * API contract types for the HMS gateway (/api/v1).
 * Keep in sync with backend DTOs (see backend/modules/** /Contracts).
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

export type Sex = 'female' | 'male' | 'other' | 'unknown'

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

export interface MembershipDto {
  tenantId: Guid
  tenantName: string
  branchId: Guid | null
  branchName: string | null
  role: string
}

export interface CurrentUser {
  userId: Guid
  email: string | null
  activeTenantId: Guid | null
  activeBranchId: Guid | null
  memberships: MembershipDto[]
}
