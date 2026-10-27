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
  /** 409 time_zone_has_future_bookings: bookings that would move on the wall clock; resend with confirmFutureBookings. */
  futureBookings?: number
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

/** WhatsApp on create / update: the phone itself, a separate number, or none (null). */
export interface WhatsappInput {
  sameAsPhone: boolean
  number?: string | null
}

/** One stored number (E.164). Phone and WhatsApp being the same number is ONE entry with both flags. */
export interface PatientPhone {
  number: string
  isPrimary: boolean
  isWhatsapp: boolean
}

/** POST /api/v1/patients. There is no MRN: the server generates it (TENANTCODE-000123) and returns it. */
export interface CreatePatientRequest {
  firstName: string
  lastName: string
  dateOfBirth?: string | null
  sex: Sex
  registeredBranchId: Guid
  phone?: string | null
  email?: string | null
  whatsapp?: WhatsappInput | null
  /** Optional ABHA number (14 digits); the server stores it as XX-XXXX-XXXX-XXXX. */
  abhaNumber?: string | null
  /** Required when the name matches a live patient (date of birth may be blank). Email, phone and ABHA cannot be overridden. */
  duplicateOverrideReason?: string | null
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
  'accountant',
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
  /** Effective IANA zone of the branch (its override, else the tenant zone). Newer API only. */
  timeZone?: string | null
}

export interface CurrentUser {
  userId: Guid
  email: string | null
  activeTenantId: Guid | null
  activeBranchId: Guid | null
  roles: string[]
  accessibleBranches: BranchOption[]
  memberships: MembershipDto[]
  /** Effective zone of the active branch (else the tenant zone); null without a resolved tenant. Newer API only. */
  timeZone?: string | null
  /** Platform operator (identity.platform_admins): opens /platform. Grants NO tenant access. */
  isPlatformAdmin?: boolean
  /** Effective permissions in the active tenant, computed by the server from membership (RBAC). Newer API only. */
  permissions?: string[] | null
}

/** GET /api/v1/tenants/current. `timeZone` (the hospital's required zone) comes with the audit/TZ API. */
export interface CurrentTenant {
  id: Guid
  code: string
  name: string
  activeBranchId: Guid | null
  roles: string[]
  timeZone?: string | null
  /** E.164 calling code applied to phones typed without one (e.g. "+91"). */
  defaultCountryCode?: string | null
  /** Wizard step. Absent on an older API, which the dashboard treats as already finished. */
  setupStep?: string | null
  /** UTC timestamp when setup finished. Null while the wizard is still open. */
  setupCompletedOn?: string | null
}

/** PATCH /api/v1/tenants/current (tenant_admin). 409 time_zone_has_future_bookings / time_zone_locked. */
export interface UpdateTenantRequest {
  name?: string
  timeZone?: string
  confirmFutureBookings?: boolean
  defaultCountryCode?: string
}

export interface SwitchContextRequest {
  tenantId: Guid
  branchId?: Guid | null
}

export interface Branch {
  id: Guid
  code: string
  name: string
  /** EFFECTIVE zone: the branch override, else the tenant's zone. */
  timezone: string
  isActive: boolean
  /** The branch's own override; null = inherits the tenant zone. Undefined on the older API. */
  timezoneOverride?: string | null
  isDeleted?: boolean
  /** Street address. Null when the hospital has not set one. */
  address?: string | null
}

export interface CreateBranchRequest {
  code: string
  name: string
  /** Optional override; omit to inherit the hospital (tenant) zone. */
  timezone?: string
  /** Omitted when blank so an empty address is not stored. */
  address?: string
}

export interface UpdateBranchRequest {
  name?: string
  timezone?: string
  /** true clears the override so the branch follows the tenant zone again. */
  inheritTimezone?: boolean
  /** Required (true) to change the zone of a branch that has future bookings; otherwise 409. */
  confirmFutureBookings?: boolean
  isActive?: boolean
  address?: string
}

/** GET /api/v1/setup. The server uses the JWT tenant; the client never sends one. */
export interface SetupState {
  step: 'profile' | 'branch' | 'staff' | 'schedule' | 'done'
  completedOn: string | null
  branchId: string | null
  documentPrefix: string | null
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
  /** Move a branch-scoped member to this branch. */
  branchId?: Guid
  /** Make the membership tenant-wide (all branches). */
  allBranches?: boolean
}

// ---------------------------------------------------------------------------------------------
// Level 1: invite links, public hospital registration and the platform console.
// ---------------------------------------------------------------------------------------------

/** A one-time invite link (token shown once; the server keeps only its hash). */
export interface InviteLinkIssued {
  id: Guid
  token: string
  /** App path of the invite page: `/invite/<token>`. */
  path: string
  expiresOn: string
}

export interface InviteLink {
  id: Guid
  email: string
  role: string
  branchId: Guid | null
  status: 'pending' | 'claimed' | 'revoked' | 'expired' | string
  expiresOn: string
  createdOn: string
  claimedOn: string | null
}

export interface CreateInviteLinkRequest {
  email: string
  role: Role
  branchId?: Guid | null
}

export interface InvitePreview {
  tenantName: string
  role: string
  branchName: string | null
  emailHint: string
  expiresOn: string
}

export interface ClaimedInvite {
  tenantId: Guid
  tenantName: string
  role: string
  branchId: Guid | null
}

export interface HospitalSignupRequest {
  hospitalName: string
  timeZone: string
  contactName: string
  contactEmail: string
  phone: string
  city: string
  /** Honeypot; always empty for people. */
  website?: string
}

export type HospitalRequestStatus = 'pending' | 'approved' | 'rejected'

export interface HospitalRequest {
  id: Guid
  hospitalName: string
  timeZone: string
  contactName: string
  contactEmail: string
  phone: string
  city: string
  status: HospitalRequestStatus
  decisionReason: string | null
  decidedOn: string | null
  tenantId: Guid | null
  tenantCode: string | null
  createdOn: string
  /** Live match against a hospital or another pending request. The approver decides. */
  possibleDuplicate: boolean
  /** Hospital names of the matches. Empty when possibleDuplicate is false. */
  matchedHospitals: string[]
}

export interface HospitalApproved {
  tenantId: Guid
  invite: InviteLinkIssued
}

export type PlatformTenantStatus = 'active' | 'suspended' | 'archived'

export interface PlatformTenant {
  id: Guid
  code: string
  name: string
  status: PlatformTenantStatus | string
  timeZone: string
  createdOn: string
  branchCount: number
  userCount: number
  pendingInvites: number
  statusReason: string | null
}

export interface TenantStatusChange {
  fromStatus: string
  toStatus: string
  reason: string
  changedOn: string
  changedBy: string | null
}

export interface PlatformTenantDetail {
  tenant: PlatformTenant
  history: TenantStatusChange[]
}

export interface PlatformCreateTenantRequest {
  code: string
  name: string
  timeZone: string
  adminEmail: string
}

// ---------------------------------------------------------------------------------------------
// Sprint 2 — /workspace/SPRINT2-CONTRACT.md (DB v2 + API v1, 2026-10-09 16:35 IST).
// ---------------------------------------------------------------------------------------------

/** GET /api/v1/patients/{id} (PatientDetailDto). Deleted patients are 404 for everyone, admins included. */
export interface PatientDetail extends PatientSummary {
  email: string | null
  createdOn?: string
  updatedOn?: string
  /** Level 1: normalized numbers (E.164); `phone` is the primary one. */
  phones?: PatientPhone[]
  /** Level 1: the phone number is also the WhatsApp number. */
  whatsappSameAsPhone?: boolean
  /** ABHA number, XX-XXXX-XXXX-XXXX (null when not recorded). */
  abhaNumber?: string | null
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
  /** null removes WhatsApp; absent leaves it unchanged. */
  whatsapp?: WhatsappInput | null
  /** Sent when a same-name chart is confirmed as a different person. */
  duplicateOverrideReason?: string | null
}

/** POST /api/v1/patients/duplicates. Email, phone and ABHA are hard matches; name is a warning. */
export interface DuplicateCheckRequest {
  firstName?: string
  lastName?: string
  dateOfBirth?: string | null
  phone?: string | null
  email?: string | null
  abhaNumber?: string | null
  excludePatientId?: Guid
}

export type DuplicateMatchReason = 'name_dob' | 'name' | 'phone' | 'email' | 'abha'

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

/** GET /api/v1/practitioners (tenant-wide; which branches they work at is practitioner-branches). */
export interface Practitioner {
  id: Guid
  userId: Guid | null
  displayName: string
  specialty: string | null
  isActive: boolean
  /** Only ever true in the admin list with includeDeleted (restore). */
  isDeleted?: boolean
  registrationNumber?: string | null
  councilName?: string | null
  qualifications?: string | null
  departmentId?: Guid | null
  phone?: string | null
  email?: string | null
}

export interface Department {
  id: Guid
  name: string
  isActive: boolean
}

/** Effective amounts are the branch override when one exists, otherwise the hospital default. Fees are paise. */
export interface VisitType {
  id: Guid
  code: string
  name: string
  defaultFeePaise: number
  durationMinutes: number
  followUpValidDays: number | null
  followUpFeePaise: number | null
  /** Free or reduced follow-ups allowed per window (default 1). Null = no limit. */
  followUpFreeLimit?: number | null
  sortOrder: number
  isActive: boolean
  effectiveFeePaise: number
  effectiveDurationMinutes: number
  effectiveFollowUpValidDays: number | null
  effectiveFollowUpFeePaise: number | null
}

export interface VisitSuggestion {
  visitTypeId: Guid | null
  code: string | null
  name: string | null
  durationMinutes: number | null
  feePaise: number | null
  suggested: boolean
  priorAppointmentId: Guid | null
  reason: string | null
}

export interface CreatePractitionerRequest {
  displayName: string
  specialty?: string | null
  userId?: Guid | null
  registrationNumber?: string | null
  councilName?: string | null
  qualifications?: string | null
  departmentId?: Guid | null
  phone?: string | null
  email?: string | null
}

/** Merge-patch: absent = unchanged; unlinkUser clears the staff account link. */
export interface UpdatePractitionerRequest {
  displayName?: string
  specialty?: string | null
  userId?: Guid
  isActive?: boolean
  unlinkUser?: boolean
  registrationNumber?: string | null
  councilName?: string | null
  qualifications?: string | null
  departmentId?: Guid | null
  clearDepartment?: boolean
  phone?: string | null
  email?: string | null
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
  /** Only ever true in the admin list with includeDeleted (restore). */
  isDeleted?: boolean
}

export interface CreateScheduleRequest {
  practitionerId: Guid
  branchId: Guid
  weekday: number
  startTime: string
  endTime: string
  slotMinutes: number
  validFrom: string
  validTo?: string | null
}

/** Merge-patch; clearValidTo removes the end date. 409 schedule_overlap on overlapping hours. */
export interface UpdateScheduleRequest {
  weekday?: number
  startTime?: string
  endTime?: string
  slotMinutes?: number
  validFrom?: string
  validTo?: string
  clearValidTo?: boolean
  isActive?: boolean
}

/** A branch the practitioner works at, with optional room and fee placeholders. */
export interface PractitionerBranchMembership {
  id: Guid
  practitionerId: Guid
  branchId: Guid
  isActive: boolean
  consultationRoom: string | null
  consultationFeeCents: number | null
}

export interface CreatePractitionerBranchRequest {
  practitionerId: Guid
  branchId: Guid
  consultationRoom?: string | null
  consultationFeeCents?: number | null
}

export interface UpdatePractitionerBranchRequest {
  isActive?: boolean
  consultationRoom?: string | null
  consultationFeeCents?: number | null
  clearFee?: boolean
}

/** One branch-local day that replaces the weekly template. */
export interface ScheduleOverride {
  id: Guid
  practitionerId: Guid
  branchId: Guid
  date: string
  isLeave: boolean
  startTime: string | null
  endTime: string | null
  slotMinutes: number | null
  isActive: boolean
}

export interface CreateScheduleOverrideRequest {
  practitionerId: Guid
  branchId: Guid
  date: string
  isLeave: boolean
  startTime?: string | null
  endTime?: string | null
  slotMinutes?: number | null
}

export interface SchedulingSettings {
  travelBufferMinutes: number
}

/** Doctor's day across every branch they work at. */
export interface MyDayItem {
  kind: 'appointment' | 'hours' | 'leave'
  branchId: Guid
  startsAt: string
  endsAt: string
  appointmentId: string | null
  status: string | null
  patient: { id: Guid; mrn: string; firstName: string; lastName: string } | null
}

export interface MyDay {
  practitionerId: Guid | null
  displayName: string | null
  date: string
  items: MyDayItem[]
}

/** GET /api/v1/patients/stats: dashboard counts (no PHI). "Today" = each branch's local day. */
export interface PatientStats {
  total: number
  registeredToday: number
}

/** POST /appointments/{id}/reschedule: only `booked`; 409 appointment_overlap. */
export interface RescheduleAppointmentRequest {
  startsAt: string
  endsAt: string
  practitionerId?: Guid
  /** Admins only, when the new time is outside working hours. */
  overrideWorkingHours?: boolean
  /** Required when overrideWorkingHours turns the override on and the visit has no reason yet. */
  reason?: string
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

/**
 * Patient summary embedded in appointment and queue responses (contract API v2, 16:50 IST).
 * `patient: null` = soft-deleted or not readable (shown as unavailable). The field is optional so
 * an older API without it still works (the UI then looks patients up by id).
 */
export interface PatientRef {
  id: Guid
  mrn: string
  firstName: string
  lastName: string
}

/** AppointmentDto. Practitioner names are resolved from GET /practitioners. */
export interface Appointment {
  id: Guid
  branchId: Guid
  practitionerId: Guid
  patientId: Guid
  patient?: PatientRef | null
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
  /** Follow-up of this earlier visit (same patient). */
  parentAppointmentId?: Guid | null
  /** Booked outside the doctor's working hours by an admin override (audited). */
  hoursOverride?: boolean
}

/** GET /api/v1/appointments query (subset the UI uses). `from`/`to` are instants. Omit branchId to list a patient's visits across branches. */
export interface AppointmentQuery {
  branchId?: Guid
  from?: string
  to?: string
  practitionerId?: Guid
  patientId?: Guid
  /** Server-side status filter (one status). */
  status?: AppointmentStatus
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
  /** Follow-up: the earlier visit it continues (same patient; a doctor may book any earlier visit at a branch they can access). */
  parentAppointmentId?: Guid
  /** Admins only: book outside the doctor's working hours (checked and audited on the server). */
  overrideWorkingHours?: boolean
  /** When set, the server sets the length and the fee. Omitted when the hospital has no visit types. */
  visitTypeId?: Guid
}

export interface CancelAppointmentRequest {
  reason?: string
}

/** expired: set by the day-end close (waiting tokens). no_show remains for older rows. */
export const QUEUE_STATUSES = ['waiting', 'in_consultation', 'done', 'cancelled', 'no_show', 'expired'] as const
export type QueueStatus = (typeof QUEUE_STATUSES)[number]

/** Allowed OPD queue transitions (DB §3.1); anything else is a 409 invalid_transition. */
export interface CloseQueueDayResult {
  branchId: Guid
  queueDate: string
  expiredCount: number
}

export const QUEUE_TRANSITIONS: Record<QueueStatus, QueueStatus[]> = {
  waiting: ['in_consultation', 'cancelled'],
  in_consultation: ['done', 'cancelled'],
  done: [],
  cancelled: [],
  no_show: [],
  expired: [],
}

/** QueueEntryDto: one OPD token for a branch and branch-local day. */
export interface QueueEntry {
  id: Guid
  branchId: Guid
  queueDate: string
  /** Per tenant + branch + branch-local day, from 1. */
  tokenNo: number
  patientId: Guid
  patient?: PatientRef | null
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

/** Bill document from billing.bill_json. Amounts are integer paise. */
export interface BillLine {
  id: Guid
  lineNo: number
  serviceItemId: Guid
  code: string
  name: string
  quantity: number
  unitPricePaise: number
  taxRateBp: number
  netPaise: number
  taxPaise: number
  sacHsnCode?: string | null
  cgstPaise?: number
  sgstPaise?: number
  igstPaise?: number
  practitionerId: Guid | null
  /** Printed under the line, e.g. "Free follow-up (within 7 days of 1 Oct 2026)". */
  note?: string | null
  /** True when money already taken covers this line. Derived, not stored. */
  locked?: boolean
}

export interface BillSupplier {
  gstin: string | null
  stateCode: string | null
  name: string | null
  address: string | null
}

export interface BillPayment {
  id: Guid
  receiptNo: string | null
  amountPaise: number
  refundedPaise: number
  /** 'split' when the receipt has more than one tender. */
  mode: string | null
  kind?: 'payment' | 'advance'
  /** Amount of this receipt applied to this bill. */
  appliedPaise?: number
  /** Advance only: what is left to apply or refund. */
  advanceBalancePaise?: number | null
  tenders?: { mode: string; amountPaise: number }[]
}

export interface BillDiscount {
  id: Guid
  billLineId: Guid | null
  kind: string
  value: number
  reasonCode: string
  approvalId: Guid
}

export interface BillDocument {
  id: Guid
  billNo: string | null
  status: string
  billKind: string
  payerType: string
  accountId: Guid
  patientId: Guid
  branchId: Guid
  lines: BillLine[]
  discounts: BillDiscount[]
  payments?: BillPayment[]
  netPaise: number
  taxPaise: number
  discountPaise: number
  exactPaise: number
  roundOffPaise: number
  totalPaise: number
  cgstPaise?: number
  sgstPaise?: number
  igstPaise?: number
  allocatedPaise?: number
  duePaise: number
  placeOfSupplyState?: string | null
  supplier?: BillSupplier
}

export interface BillListItem {
  id: Guid
  billNo: string | null
  status: string
  billKind: string
  patientId: Guid
  branchId: Guid
  totalPaise: number | null
  duePaise: number | null
  createdOn: string
}

export interface BranchBillProfile {
  branchId: Guid
  docPrefix: string | null
  gstin: string | null
  legalName: string | null
}

export interface ApprovalSettings {
  makerCheckerThresholdPaise: number
  cancelRefundPctBp: number
  noShowRefundPctBp: number
}

/** GET /accounts/{patientId}/summary. Advance is unallocated receipts, in paise. */
export interface PatientBillingSummary {
  patientId: Guid
  advancePaise: number
  bills: { id: Guid; accountId: Guid; branchId: Guid; billNo: string | null; status: string; billKind: string; totalPaise: number; duePaise: number }[]
}

export interface PaymentLink {
  id: Guid
  providerOrderId: string
  channel: string
  path: string
  /** Null when the branch has no active UPI account; the QR is never built from a stub payee. */
  upiUri?: string | null
  upiConfigured?: boolean
  shareStatus?: string
}

export type PaymentAccountMode = 'bank' | 'upi' | 'card'

/** A branch's receiving account. Bank numbers are masked; only the last 4 digits are stored. */
export interface PaymentAccount {
  id: Guid
  branchId: Guid
  mode: PaymentAccountMode
  label: string
  bankName?: string | null
  maskedAccount?: string | null
  ifsc?: string | null
  vpa?: string | null
  payeeName?: string | null
  mid?: string | null
  tid?: string | null
  isDefault: boolean
  isActive: boolean
}

export interface AddPaymentAccountRequest {
  branchId: Guid
  mode: PaymentAccountMode
  label: string
  bankName?: string
  accountNumber?: string
  ifsc?: string
  vpa?: string
  payeeName?: string
  mid?: string
  tid?: string
  isDefault?: boolean
}

export interface Receipt {
  id: Guid
  receiptNo: string | null
  kind: string
  amountPaise: number
  accountId: Guid
  counterSessionId?: Guid | null
  tenders: { mode: string; amountPaise: number; reference: string | null }[]
  allocations: { billId: Guid; amountPaise: number }[]
  creditNoteId?: Guid | null
  creditNoteNo?: string | null
}

export interface CashierSession {
  id: Guid | null
  businessDate?: string
  opened?: boolean
}

export interface ApprovalRequest {
  id: Guid
  action: string
  status: string
  amountPaise: number | null
  percentBp: number | null
  requestedBy: Guid | null
  approverId: Guid | null
  subjectType: string
  subjectId: Guid
  note: string | null
}

export interface EarningsMove {
  direction: 'up' | 'down' | 'flat' | 'new'
  pct: number | null
}

export interface EarningsCard {
  grossBilledPaise: number
  collectedPaise: number
  /** Advances taken in the period; not counted in collection efficiency. */
  advancesPaise?: number
  refundsPaise: number
  netEarningsPaise: number
  outstandingPaise: number
  discountPaise: number
  cgstPaise: number
  sgstPaise: number
  igstPaise: number
  billCount: number
  averageBillPaise: number | null
  visitCount: number
  doctorCount: number
  revenuePerVisitPaise: number | null
  revenuePerDoctorPaise: number | null
  collectionEfficiencyPct: number | null
  refundRatePct: number | null
  discountRatePct: number | null
  periodGrowthPct: number | null
  momGrowthPct: number | null
  yoyGrowthPct: number | null
  deltas: {
    grossBilled: EarningsMove
    collected: EarningsMove
    netEarnings: EarningsMove
    refunds: EarningsMove
    billCount: EarningsMove
    averageBill: EarningsMove
    collectionEfficiency: EarningsMove
    refundRate: EarningsMove
    mom: EarningsMove
    yoy: EarningsMove
  }
}

export interface EarningsBranch {
  branchId: string
  name: string
  gstin: string
  deleted: boolean
  rank: number
  sharePct: number
  grossBilledPaise: number
  collectedPaise: number
  netEarningsPaise: number
  outstandingPaise: number
  billCount: number
  periodGrowthPct: number | null
  direction: EarningsMove['direction']
}

export interface EarningsReport {
  from: string
  to: string
  grain: 'day' | 'week' | 'month'
  branchId: string | null
  financialYear: number | null
  quarter: number | null
  level: 'tenant' | 'branch'
  tenant: EarningsCard
  focus: EarningsCard
  branches: EarningsBranch[]
  trend: { bucket: string; grossBilledPaise: number; collectedPaise: number; netEarningsPaise: number }[]
  doctors: { practitionerId: string; name: string; rank: number; revenuePaise: number; visits: number }[]
  services: { serviceItemId: string; name: string; code: string; sac: string; revenuePaise: number; sharePct: number }[]
  paymentModes: { mode: string; collectedPaise: number; refundsPaise: number; sharePct: number }[]
  ageing: { b0To30Paise: number; b31To60Paise: number; b61To90Paise: number; b90PlusPaise: number }
  topBottom: { topBranch: string | null; bottomBranch: string | null; topDoctor: string | null; bottomDoctor: string | null }
  insights: string[]
  gstr1: Record<string, string | number>[]
  gstr3b: Record<string, string | number>[]
  hsn: Record<string, string | number>[]
  sales: Record<string, string | number>[]
  creditNotes: Record<string, string | number>[]
  refunds: Record<string, string | number>[]
  receipts: Record<string, string | number>[]
  dayEndCash: Record<string, string | number>[]
  truncated: boolean
}

export interface DayEndSession {
  sessionId: Guid
  counterId: Guid
  cashierId: Guid
  status: string
  openingFloatPaise: number
  /** Float plus cash receipts, minus cash refunds. Same figure close_session returns. */
  expectedCashPaise: number
  countedCashPaise: number | null
  /** Counted minus expected, once the cashier has counted. Empty while the session is still open. */
  variancePaise: number | null
  businessDate: string
}

export interface PublicBill extends BillDocument {
  linkStatus: string
  channel: string
}

/** GET /service-items. Amounts are integer paise. hospitalPricePaise is the open hospital rate. */
export interface ServiceItem {
  id: Guid
  code: string
  name: string
  category: string
  taxCodeId: Guid
  sacHsnCode: string
  taxRateBp: number
  isExempt: boolean
  isActive: boolean
  isStockTracked: boolean
  hospitalPricePaise: number | null
}

export interface TaxCode {
  id: Guid
  code: string
  sacHsnCode: string
  isExempt: boolean
  rateBp: number
  effectiveFrom: string
  effectiveTo: string | null
}

/** GET /service-items/category-defaults. The tax is a reference, not a copied SAC. */
export interface CategoryDefault {
  category: string
  codePrefix: string
  taxCodeId: Guid
  sacHsnCode: string
  rateBp: number
  isExempt: boolean
}

export interface PriceListSummary {
  id: Guid
  name: string
  branchId: Guid | null
  isActive: boolean
  isPublicDisplay: boolean
  schemeCode: string | null
}

export interface ServicePrice {
  id: Guid
  priceListId: Guid
  priceListName: string
  branchId: Guid | null
  practitionerId: Guid | null
  unitPricePaise: number
  effectiveFrom: string
  effectiveTo: string | null
}

/** `code` is not a field. The server allocates it and rejects a client value with 400. */
export interface SaveServiceItemRequest {
  id?: Guid
  name?: string
  category?: string
  taxCodeId?: Guid
  isActive?: boolean
  isStockTracked?: boolean
}

export interface AddPriceRequest {
  serviceItemId: Guid
  unitPricePaise: number
  effectiveFrom: string
  effectiveTo?: string
  branchId?: Guid
  practitionerId?: Guid
  priceListId?: Guid
}

/** `code` is not a column. The server ignores one if a client still sends it, and matches name + category. */
export interface PriceImportRow {
  clientIndex: number
  name: string
  category?: string
  sac?: string
  unitPricePaise: number
  effectiveFrom: string
  effectiveTo?: string
  branchId?: Guid
  practitionerId?: Guid
}

export interface PriceImportRowResult {
  clientIndex: number
  code: string | null
  name: string | null
  status: 'ready' | 'error' | 'price_overlap' | string
  detail: string | null
  item: 'create' | 'existing' | null
  unitPricePaise: number | null
}

export interface PriceImportResult {
  dryRun: boolean
  rows: PriceImportRowResult[]
}

export interface CopyPriceConflict {
  code: string
  name: string
  practitionerId: Guid | null
  reason: string
}

export interface CopyPriceResult {
  priceListId: Guid | null
  copied: number
  conflicts: CopyPriceConflict[]
  dryRun: boolean
}

export interface StockUom {
  code: string
  name: string
}

export interface StockPack {
  uomCode: string
  unitsPerPack: number
  isPurchase: boolean
  isSale: boolean
}

export interface StockItem {
  id: Guid
  code: string
  itemKind: string
  brandName: string
  genericName: string | null
  strength: string | null
  dosageForm: string | null
  route: string | null
  manufacturerName: string
  scheduleCode: string | null
  hsnCode: string
  gstRateBp: number
  baseUomCode: string
  isColdChain: boolean
  isHighAlert: boolean
  isLasa: boolean
  isActive: boolean
  packs: StockPack[]
}

export interface StockCatalog {
  items: StockItem[]
  uoms: StockUom[]
}

export interface CreateStockItemRequest {
  itemKind: string
  brandName: string
  genericName?: string
  strength?: string
  dosageForm?: string
  route?: string
  manufacturerName: string
  scheduleCode?: string
  hsnCode: string
  gstRateBp: number
  baseUomCode: string
  packs?: { uomCode: string; unitsPerPack: number; isPurchase: boolean; isSale: boolean }[]
  isColdChain?: boolean
  isHighAlert?: boolean
  isLasa?: boolean
  storeId?: Guid
  reorderLevel?: number
}

export interface StockStore {
  id: Guid
  code: string
  branchId: Guid
  name: string
  storeKind: string
  drugLicenceNo: string | null
  licenceValidTo: string | null
  isActive: boolean
}

export interface CreateStockStoreRequest {
  branchId: Guid
  name: string
  storeKind: string
  drugLicenceNo?: string
  licenceValidTo?: string
}

export interface OpeningStockLine {
  itemId: Guid
  batchNo: string
  expiryDate: string
  mfgDate?: string
  mrpPaise: number
  purchaseRatePaise: number
  qtyBase: number
}

export interface OpeningStockDocument {
  id: Guid
  docNo: string
  storeId: Guid
  approvalRequestId: Guid
  approverId: Guid
  lines: { id: Guid; batchId: Guid; itemId: Guid; batchNo: string; expiryDate: string; mrpPaise: number; qtyBase: number }[]
}

export interface StockOnHandRow {
  storeId: Guid
  storeCode: string
  storeName: string
  itemId: Guid
  itemCode: string
  brandName: string
  batchId: Guid
  batchNo: string
  expiryDate: string
  mrpPaise: number
  purchaseRatePaise: number
  onHandBase: number
  baseUomCode: string
  /** store_item_policy.min_qty when this store tracks a reorder level for the item. */
  minQty: number | null
  /** True when on-hand for the store and item is below minQty. */
  lowStock: boolean
  expiryState: 'expired' | 'soon' | 'ok'
}

export interface PrivacyPurpose {
  code: string
  label: string
  required: boolean
  granted?: boolean
}

export interface PrivacyNotice {
  noticeId: string
  version: number
  language: string
  title: string
  body: string
  uri?: string | null
  contentSha256: string
  publishedAt?: string | null
  purposes: PrivacyPurpose[]
}

export interface ConsentChoice {
  purposeCode: string
  granted: boolean
}

export interface ConsentCurrent {
  purposeCode: string
  label: string
  granted: boolean
  since: string
  noticeVersion: number
}

export interface ConsentHistory {
  purposeCode: string
  action: string
  occurredAt: string
  noticeVersion: number
  channel: string
  givenBy: string
  patientId: string
}

export interface ConsentList {
  current: ConsentCurrent[]
  history: ConsentHistory[]
}

export interface ConsentLink {
  expiresAt: string
  path: string
}

export interface RightsRequest {
  id: string
  code: string
  patientId: string
  type: string
  details: string
  channel: string
  status: string
  receivedAt: string
  dueAt: string
  daysRemaining: number
  response?: string | null
}

export interface PublicConsent extends PrivacyNotice {
  purposes: PrivacyPurpose[]
}

export type FoodTiming = 'before_food' | 'after_food' | 'with_food' | 'any'

export interface PrescriptionLine {
  lineNo?: number
  medicineName: string
  inventoryItemId?: string | null
  strength: string | null
  dose: string | null
  frequency: string
  durationDays: number | null
  route: string | null
  foodTiming: FoodTiming | null
  instructions: string | null
}

export type ConsultationStatus = 'draft' | 'finalized'

/** OPD consultation (clinical v1). Finalized rows are immutable; a correction is a new version. */
export interface Consultation {
  id: string
  branchId: string
  patientId: string
  practitionerId: string
  practitionerName: string
  queueEntryId: string | null
  appointmentId: string | null
  rootId: string
  version: number
  supersedesId: string | null
  isLatest: boolean
  status: ConsultationStatus
  chiefComplaint: string | null
  notes: string | null
  diagnosisText: string | null
  diagnosisCode: string | null
  followUpDate: string | null
  advice: string | null
  finalizedOn: string | null
  rowVersion: number
  createdOn: string
  updatedOn: string
  lines: PrescriptionLine[]
}

export type SaveConsultationRequest = Pick<Consultation, 'chiefComplaint' | 'notes' | 'diagnosisText' | 'diagnosisCode' | 'followUpDate' | 'advice'> & {
  rowVersion: number
  lines: PrescriptionLine[]
}

export interface ConsultationPrint extends Consultation {
  branch: { name: string; address: string | null } | null
  tenantName: string
  timeZone: string | null
  doctor: { name: string; registrationNumber: string | null; council: string | null; qualifications: string | null } | null
  patient: { mrn: string; name: string; dateOfBirth: string | null; sex: string | null } | null
}

/** #104 triage vitals for one visit. Units: mmHg, /min, °C, kg, cm, %. */
export type VitalsField = 'systolic' | 'diastolic' | 'pulse' | 'temperature' | 'spo2' | 'respRate'
export interface VitalsFlag {
  field: VitalsField
  level: 'high' | 'low' | 'critical'
}
export interface Vitals {
  id: string
  patientId: string
  queueEntryId: string
  branchId: string
  recordedOn: string
  recordedBy: string
  systolic: number | null
  diastolic: number | null
  pulse: number | null
  temperatureC: number | null
  weightKg: number | null
  heightCm: number | null
  bmi: number | null
  spo2: number | null
  respRate: number | null
  note: string | null
  flags: VitalsFlag[]
}
export interface RecordVitalsRequest {
  queueEntryId: string
  /** Double-submit key: the same clientId returns the first reading. */
  clientId: string
  systolic?: number
  diastolic?: number
  pulse?: number
  temperatureC?: number
  weightKg?: number
  heightCm?: number
  spo2?: number
  respRate?: number
  note?: string
}

/** #106 pharmacy dispensing (inventory service, ADR 0004). */
export type RxDispenseStatus = 'pending' | 'partial' | 'dispensed'

export interface PharmacyQueueRow {
  id: Guid
  branchId: Guid
  patientId: Guid
  patientName: string
  patientMrn: string
  doctorName: string
  finalizedOn: string
  lineCount: number
  status: RxDispenseStatus
}

export interface PharmacyRxLine {
  id: Guid
  lineNo: number
  medicineName: string
  strength: string | null
  dose: string
  frequency: string
  durationDays: number
  route: string | null
  foodTiming: string | null
  instructions: string | null
  inventoryItemId: Guid | null
  dispensedBase: number
  complete: boolean
  availableBase: number | null
}

export interface PharmacyDispenseRecord {
  id: Guid
  storeId: Guid
  dispensedBy: Guid
  createdOn: string
  note: string | null
  lines: { prescriptionLineId: Guid; itemId: Guid; brandName: string; batchId: Guid; batchNo: string; expiryDate: string; qtyBase: number; completesLine: boolean }[]
}

export interface PharmacyPrescription {
  id: Guid
  branchId: Guid
  patientId: Guid
  patientName: string
  patientMrn: string
  practitionerId: Guid
  doctorName: string
  finalizedOn: string
  version: number
  diagnosisText: string | null
  superseded: boolean
  status: RxDispenseStatus
  lines: PharmacyRxLine[]
  dispenses: PharmacyDispenseRecord[]
}

export interface DispenseRequest {
  consultationId: Guid
  storeId: Guid
  note?: string
  lines: { lineNo: number; itemId?: Guid; qtyBase: number; complete: boolean }[]
}
