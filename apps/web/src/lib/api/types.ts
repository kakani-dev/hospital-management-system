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
  /** Sprint 2 machine-readable reason, e.g. appointment_overlap, already_checked_in, invalid_state. */
  code?: string
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
  /** Sprint 2: part of PatientSummaryDto. */
  phone?: string | null
  /** Sprint 2: only ever non-null for admins searching with includeDeleted. */
  deletedAt?: string | null
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
  status: 'active' | 'invited' | 'suspended' | string
}

export interface AddMemberRequest {
  email: string
  role: Role
  branchId?: Guid | null
}

/**
 * POST /api/v1/members always answers 202 with this body — for "no account", "invited" and
 * "already a member" alike — so the response never reveals whether an email has an account.
 */
export interface AddMemberResponse {
  message: string
}

export const ADD_MEMBER_GENERIC_MESSAGE = 'If an account exists for that email, an invitation has been sent.'

/** GET /api/v1/me/invitations (identity.my_invitations()): memberships waiting for the invitee's consent. */
export interface Invitation {
  membershipId: Guid
  tenantId: Guid
  tenantName: string
  branchId: Guid | null
  /** Not part of the my_invitations() contract; shown if the API ever adds it. */
  branchName?: string | null
  role: string
  invitedAt: string
}

/** POST /api/v1/patients/search — the search term travels in the body, never in the URL (PHI). */
export interface PatientSearchRequest {
  /** Name or MRN fragment. */
  search?: string
  /** Sprint 2: exact match on the normalized phone (last 10 digits; fewer than 7 digits is a 400). */
  phone?: string
  /** Sprint 2: exact date of birth, YYYY-MM-DD. */
  dateOfBirth?: string
  /** Sprint 2: tenant_admin only (403 otherwise); deleted rows come back with deletedAt set. */
  includeDeleted?: boolean
  page?: number
  pageSize?: number
}

export interface UpdateMemberRequest {
  role?: Role
  status?: 'active' | 'suspended'
}

// ---------------------------------------------------------------------------------------------
// Sprint 2 — /workspace/SPRINT2-CONTRACT.md (DB v2 + API v1, 2026-10-09 16:35 IST).
// ---------------------------------------------------------------------------------------------

/** GET /api/v1/patients/{id} (PatientDetailDto). Deleted patients are 404 for everyone, admins included. */
export interface PatientDetail extends PatientSummary {
  email: string | null
  createdAt?: string
  updatedAt?: string
}

/**
 * PATCH /api/v1/patients/{id}: merge-patch. Absent = unchanged, explicit null clears
 * dateOfBirth/phone/email. MRN is immutable; unknown properties are a 400.
 */
export interface UpdatePatientRequest {
  firstName?: string
  lastName?: string
  dateOfBirth?: string | null
  sex?: Sex
  registeredBranchId?: Guid
  phone?: string | null
  email?: string | null
}

/** POST /api/v1/patients/duplicates (advisory, D3). */
export interface DuplicateCheckRequest {
  firstName?: string
  lastName?: string
  dateOfBirth?: string | null
  phone?: string | null
  excludePatientId?: Guid
}

export type DuplicateMatchReason = 'name_dob' | 'phone'

/** DuplicateCandidateDto. */
export interface DuplicateCandidate {
  id: Guid
  mrn: string
  firstName: string
  lastName: string
  dateOfBirth: string | null
  phone: string | null
  registeredBranchId: Guid
  matchReasons: DuplicateMatchReason[]
}

/** DELETE /api/v1/patients/{id} optional body (reason is audited, ≤ 500). */
export interface DeletePatientRequest {
  reason?: string
}

/** GET /api/v1/practitioners (tenant-wide; branch association comes from schedules). */
export interface Practitioner {
  id: Guid
  userId: Guid | null
  displayName: string
  specialty: string | null
  isActive: boolean
}

/** Weekly recurring working hours at a branch (ScheduleDto). Times are branch-local wall clock. */
export interface Schedule {
  id: Guid
  practitionerId: Guid
  branchId: Guid
  /** ISO weekday, 1 = Monday … 7 = Sunday. */
  weekday: number
  startTime: string
  endTime: string
  slotMinutes: number
  validFrom: string
  validTo: string | null
  isActive: boolean
}

/** GET /api/v1/slots: only free, future slots. */
export interface Slot {
  practitionerId: Guid
  branchId: Guid
  startsAt: string
  endsAt: string
}

export const APPOINTMENT_STATUSES = ['booked', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show'] as const
export type AppointmentStatus = (typeof APPOINTMENT_STATUSES)[number]

/** AppointmentDto. Names are not embedded: resolve practitioner/patient by id. */
export interface Appointment {
  id: Guid
  branchId: Guid
  practitionerId: Guid
  patientId: Guid
  /** Instants (UTC …Z); render in the branch time zone. */
  startsAt: string
  endsAt: string
  status: AppointmentStatus
  reason: string | null
  cancelReason?: string | null
  checkedInAt?: string | null
  startedAt?: string | null
  completedAt?: string | null
  cancelledAt?: string | null
}

/** GET /api/v1/appointments query (subset the UI uses). `from`/`to` are instants. */
export interface AppointmentQuery {
  branchId: Guid
  from: string
  to: string
  practitionerId?: Guid
  page?: number
  pageSize?: number
}

export interface CreateAppointmentRequest {
  branchId: Guid
  practitionerId: Guid
  patientId: Guid
  startsAt: string
  endsAt: string
  reason?: string
}

export interface CancelAppointmentRequest {
  reason?: string
}

export const QUEUE_STATUSES = ['waiting', 'in_consultation', 'done', 'cancelled'] as const
export type QueueStatus = (typeof QUEUE_STATUSES)[number]

/** Allowed OPD queue transitions (DB §3.1); anything else is a 409 invalid_transition. */
export const QUEUE_TRANSITIONS: Record<QueueStatus, QueueStatus[]> = {
  waiting: ['in_consultation', 'cancelled'],
  in_consultation: ['done', 'cancelled'],
  done: [],
  cancelled: [],
}

/** QueueEntryDto: one OPD token for a branch and branch-local day. */
export interface QueueEntry {
  id: Guid
  branchId: Guid
  queueDate: string
  /** Per tenant + branch + branch-local day, from 1. */
  tokenNo: number
  patientId: Guid
  appointmentId: Guid | null
  practitionerId: Guid | null
  status: QueueStatus
  checkedInAt: string
  calledAt?: string | null
  completedAt?: string | null
  cancelledAt?: string | null
}

/** 201 from POST /appointments/{id}/check-in and POST /queue/walk-in. */
export interface CheckInResult {
  queueEntryId: Guid
  tokenNo: number
  queueDate: string
  entry: QueueEntry
}

export interface WalkInRequest {
  branchId: Guid
  patientId: Guid
  practitionerId?: Guid
}

export interface UpdateQueueStatusRequest {
  status: Exclude<QueueStatus, 'waiting'>
}
