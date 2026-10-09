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
  /** Sprint 2 (2.1): phone fragment — digits compared server-side. */
  phone?: string
  /** Sprint 2 (2.1): exact date of birth, YYYY-MM-DD. */
  dateOfBirth?: string
  page?: number
  pageSize?: number
}

export interface UpdateMemberRequest {
  role?: Role
  status?: 'active' | 'suspended'
}

// ---------------------------------------------------------------------------------------------
// Sprint 2 — see /workspace/SPRINT2-CONTRACT.md. Where a route had not landed when this was
// written, the shape follows SPRINT2-PLAN.md and is listed in docs/sprint-2-web-assumptions.md.
// ---------------------------------------------------------------------------------------------

/** GET /api/v1/patients/{id}. Deleted patients are 404 (hidden); `deletedAt` is shown if ever returned. */
export interface PatientDetail extends PatientSummary {
  phone: string | null
  email: string | null
  deletedAt?: string | null
  createdAt?: string
  updatedAt?: string
}

/** PATCH /api/v1/patients/{id}: MRN and tenant are immutable; omitted fields are unchanged. */
export interface UpdatePatientRequest {
  firstName?: string
  lastName?: string
  dateOfBirth?: string | null
  sex?: Sex
  registeredBranchId?: Guid
  phone?: string | null
  email?: string | null
}

/** POST /api/v1/patients/duplicates: possible matches in the same tenant (name+DOB or phone). */
export interface DuplicateCheckRequest {
  firstName: string
  lastName: string
  dateOfBirth?: string | null
  phone?: string | null
}

export type DuplicateMatchReason = 'name_dob' | 'phone'

export interface PossibleDuplicate extends PatientSummary {
  matchReasons: DuplicateMatchReason[]
}

/** Clinicians that can be booked at a branch (GET /api/v1/practitioners?branchId=). */
export interface Practitioner {
  id: Guid
  displayName: string
  role: string
  /** null = tenant-wide practitioner. */
  branchId: Guid | null
}

/** One working block of a practitioner on a branch-local date (GET /api/v1/schedules). */
export interface ScheduleEntry {
  id: Guid
  practitionerId: Guid
  practitionerName: string
  branchId: Guid
  /** Branch-local calendar date, YYYY-MM-DD. */
  date: string
  /** Branch-local wall-clock time, HH:mm. */
  startTime: string
  endTime: string
  slotMinutes: number
}

/** GET /api/v1/appointments/slots: bookable slots for one practitioner on one branch-local date. */
export interface Slot {
  startsAt: string
  endsAt: string
  available: boolean
}

export const APPOINTMENT_STATUSES = ['booked', 'checked_in', 'completed', 'cancelled', 'no_show'] as const
export type AppointmentStatus = (typeof APPOINTMENT_STATUSES)[number]

export interface Appointment {
  id: Guid
  branchId: Guid
  practitionerId: Guid
  practitionerName: string
  patientId: Guid
  patientName: string
  patientMrn: string
  /** ISO-8601 instants (with offset); render in the branch time zone. */
  startsAt: string
  endsAt: string
  status: AppointmentStatus
  reason?: string | null
}

export interface AppointmentRangeQuery {
  branchId: Guid
  /** Branch-local dates, inclusive (YYYY-MM-DD). */
  from: string
  to: string
  practitionerId?: Guid
}

export interface CreateAppointmentRequest {
  branchId: Guid
  practitionerId: Guid
  patientId: Guid
  startsAt: string
  endsAt: string
  reason?: string | null
}

export const QUEUE_STATUSES = ['waiting', 'in_consult', 'done'] as const
export type QueueStatus = (typeof QUEUE_STATUSES)[number]

/** Allowed OPD queue transitions (anything else is a 409 from the API). */
export const QUEUE_TRANSITIONS: Record<QueueStatus, QueueStatus[]> = {
  waiting: ['in_consult'],
  in_consult: ['done'],
  done: [],
}

/** One OPD queue token for a branch and branch-local day. */
export interface QueueEntry {
  id: Guid
  branchId: Guid
  /** Branch-local date the token belongs to. */
  queueDate: string
  /** Per branch per day, starting at 1. */
  tokenNumber: number
  patientId: Guid
  patientName: string
  patientMrn: string
  appointmentId: Guid | null
  practitionerId: Guid | null
  practitionerName: string | null
  status: QueueStatus
  checkedInAt: string
}

/** POST /api/v1/queue/check-in. Same patient twice in a branch-day is a 409. */
export interface CheckInRequest {
  branchId: Guid
  patientId: Guid
  appointmentId?: Guid | null
  practitionerId?: Guid | null
}

export interface UpdateQueueStatusRequest {
  status: QueueStatus
}
