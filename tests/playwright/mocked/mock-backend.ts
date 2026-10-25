import type { BrowserContext, Page, Request, Route } from '@playwright/test'

/**
 * In-page mock of Supabase Auth (GoTrue) + the HMS API, following the PR #1 contracts in
 * /workspace/review-pr1/FIX-PLAN.md (incl. the 21:16 IST updates):
 * - every API response with a resolved tenant carries X-Hms-Tenant (absent when none);
 * - GET /api/v1/patients?search= -> 400; POST /api/v1/patients/search {search, page, pageSize};
 *   search > 100 chars -> 400;
 * - POST /api/v1/members -> always 202 {message}; tenant_admin + branchId -> 400; pending invites
 *   are not listed in GET /api/v1/members;
 * - GET /api/v1/me/invitations -> [{membershipId, tenantId, tenantName, branchId, role, invitedAt}],
 *   POST /api/v1/me/invitations/{id}/accept -> 204 | 404; both work without a resolved tenant.
 * Sprint 2 (/workspace/SPRINT2-CONTRACT.md, DB v2 + API v1):
 * - patients: GET/PATCH/DELETE /patients/{id} (soft delete → 404; 409 invalid_state with open
 *   appointments/queue), POST /patients/{id}/restore (admin), POST /patients/duplicates
 *   {candidates}, search body {search, phone (≥ 7 digits, last 10 compared), dateOfBirth, includeDeleted};
 * - GET /practitioners[?branchId] (API v2: practitioners with a schedule at the branch),
 *   GET /schedules?branchId (weekly), GET /slots (free + future only);
 * - GET /appointments (Paged, from/to instants), POST /appointments (409 appointment_overlap),
 *   POST /appointments/{id}/cancel, POST /appointments/{id}/check-in (today only);
 * - GET /queue?branchId&date, POST /queue/walk-in, PATCH /queue/{id} (transition rules, doctor may
 *   only call in / finish); one active entry per patient per branch-day (409 already_checked_in).
 * API v2 (contract 16:50 IST): appointment/queue/check-in/walk-in responses embed
 * `patient: { id, mrn, firstName, lastName } | null` (null when soft-deleted). `backend.legacyApi = true` simulates an older API:
 * no summary, and `?branchId=` on /practitioners → 400. POST/PATCH /patients reject a DOB after
 * today in the registered branch's zone (`backend.branchTimeZones` overrides a branch's zone).
 * Writes check the role held *at the row's branch*; branch-bound members only see their branches.
 * The resolved tenant is per USER (server-side), like identity.user_profiles, so a "switch on
 * another device" is simulated with `backend.setActiveTenant()`.
 * Level 1 (MRN + phones): POST /patients ignores a client `mrn` and assigns `<TENANT>-<6 digits>`
 * from a per-tenant counter; PATCH with a different `mrn` → 400. Phones are normalised to E.164
 * (+91 default); `whatsapp: {sameAsPhone, number?}` on create/update; detail responses carry
 * `phones[] {number, isPrimary, isWhatsapp}` + `whatsappSameAsPhone`; phone search/duplicates
 * compare every live number (the last 10 digits).
 */

export const MOCK_AUTH_URL = 'http://127.0.0.1:59999'
export const ADD_MEMBER_GENERIC_MESSAGE = 'If an account exists for that email, an invitation has been sent.'
export const PASSWORD = 'synthetic-demo-pass'

export const ids = {
  alpha: '11111111-1111-4111-8111-111111111111',
  beta: '22222222-2222-4222-8222-222222222222',
  alphaMain: 'a1111111-0000-4000-8000-000000000001',
  alphaEast: 'a1111111-0000-4000-8000-000000000002',
  betaMain: 'b2222222-0000-4000-8000-000000000001',
}

const tenants: Record<string, { name: string; branches: { id: string; name: string; code: string }[] }> = {
  [ids.alpha]: {
    name: 'Demo Alpha Hospital (synthetic)',
    branches: [
      { id: ids.alphaEast, name: 'Alpha East Clinic', code: 'east' },
      { id: ids.alphaMain, name: 'Alpha Main Campus', code: 'main' },
    ],
  },
  [ids.beta]: { name: 'Demo Beta Clinic (synthetic)', branches: [{ id: ids.betaMain, name: 'Beta Central', code: 'central' }] },
}

export const patientIds = {
  asha: 'aa000000-0000-4000-8000-000000000001',
  ravi: 'aa000000-0000-4000-8000-000000000002',
  meera: 'bb000000-0000-4000-8000-000000000001',
}

interface MockPatient {
  id: string
  tenantId: string
  mrn: string
  firstName: string
  lastName: string
  dateOfBirth: string | null
  sex: string
  registeredBranchId: string
  /** Primary phone, E.164 (mirrors patients.phone). */
  phone: string | null
  /** WhatsApp: 'same' = the phone row carries the flag; a string = a separate E.164 number. */
  whatsapp?: 'same' | string | null
  email: string | null
  deletedAt: string | null
  /** Set for patients registered during the test (GET /patients/stats). */
  createdOn?: string
}

const seedPatients = (): MockPatient[] => [
  { id: patientIds.asha, tenantId: ids.alpha, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female', registeredBranchId: ids.alphaMain, phone: '+919845000001', whatsapp: '+919800000101', email: null, deletedAt: null },
  { id: patientIds.ravi, tenantId: ids.alpha, mrn: 'ALP-0002', firstName: 'Ravi', lastName: 'Synthetic-Alpha', dateOfBirth: '1985-05-05', sex: 'male', registeredBranchId: ids.alphaEast, phone: '+919845000002', whatsapp: 'same', email: null, deletedAt: null },
  { id: patientIds.meera, tenantId: ids.beta, mrn: 'BET-0001', firstName: 'Meera', lastName: 'Synthetic-Beta', dateOfBirth: '1970-07-07', sex: 'female', registeredBranchId: ids.betaMain, phone: null, email: null, deletedAt: null },
]

/** All mock branches are in India: branch-local = UTC+05:30, no DST. */
export const BRANCH_TZ = 'Asia/Kolkata'
export const todayIn = (timeZone: string, now = new Date()) =>
  new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
export const branchToday = (now = new Date()) => todayIn(BRANCH_TZ, now)
export const branchInstant = (date: string, time: string) => new Date(`${date}T${time}:00+05:30`).toISOString()
export const addDays = (date: string, days: number) => {
  const d = new Date(`${date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}
const isoWeekday = (date: string) => ((new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7) + 1

export const practitionerIds = {
  rao: 'd0000000-0000-4000-8000-000000000001',
  iyer: 'd0000000-0000-4000-8000-000000000002',
  betaDoc: 'd0000000-0000-4000-8000-000000000003',
}

const seedPractitioners = (): MockPractitioner[] => [
  { id: practitionerIds.rao, tenantId: ids.alpha, userId: null, displayName: 'Dr. Rao (synthetic)', specialty: 'General medicine', isActive: true },
  { id: practitionerIds.iyer, tenantId: ids.alpha, userId: null, displayName: 'Dr. Iyer (synthetic)', specialty: 'Paediatrics', isActive: true },
  { id: practitionerIds.betaDoc, tenantId: ids.beta, userId: null, displayName: 'Dr. Beta (synthetic)', specialty: null, isActive: true },
]

/** Dr. Rao: every day 09:00–13:00 at Alpha Main (15 min). Dr. Iyer: every day 14:00–16:00 at Alpha East (20 min). */
const seedSchedules = (): MockSchedule[] => [
  ...[1, 2, 3, 4, 5, 6, 7].map((weekday) => ({ id: `5c000000-0000-4000-8000-00000000000${weekday}`, tenantId: ids.alpha, practitionerId: practitionerIds.rao, branchId: ids.alphaMain, weekday, startTime: '09:00', endTime: '13:00', slotMinutes: 15, validFrom: '2026-01-01', validTo: null as string | null, isActive: true })),
  ...[1, 2, 3, 4, 5, 6, 7].map((weekday) => ({ id: `5c000000-0000-4000-8000-00000000010${weekday}`, tenantId: ids.alpha, practitionerId: practitionerIds.iyer, branchId: ids.alphaEast, weekday, startTime: '14:00', endTime: '16:00', slotMinutes: 20, validFrom: '2026-01-01', validTo: null as string | null, isActive: true })),
]

interface MockPractitioner {
  id: string
  tenantId: string
  userId: string | null
  displayName: string
  specialty: string | null
  isActive: boolean
  isDeleted?: boolean
}

interface MockSchedule {
  id: string
  tenantId: string
  practitionerId: string
  branchId: string
  weekday: number
  startTime: string
  endTime: string
  slotMinutes: number
  validFrom: string
  validTo: string | null
  isActive: boolean
  isDeleted?: boolean
}

interface MockAppointment {
  id: string
  tenantId: string
  branchId: string
  practitionerId: string
  patientId: string
  startsAt: string
  endsAt: string
  status: string
  reason: string | null
  cancelReason: string | null
}

interface MockQueueEntry {
  id: string
  tenantId: string
  branchId: string
  queueDate: string
  tokenNo: number
  patientId: string
  appointmentId: string | null
  practitionerId: string | null
  status: string
  checkedInAt: string
  calledAt: string | null
  completedAt: string | null
  cancelledAt: string | null
}

const BLOCKING = ['booked', 'checked_in', 'in_consultation', 'completed']
const QUEUE_TRANSITIONS: Record<string, string[]> = { waiting: ['in_consultation', 'cancelled'], in_consultation: ['done', 'cancelled'], done: [], cancelled: [] }
/** Mirror of PhoneE164.Normalize / patient.to_e164 (tenant default calling code; +91 here). */
export const toE164 = (raw: unknown, countryCode = '+91'): string | null => {
  if (typeof raw !== 'string' || !raw.trim()) return null
  const v = raw.replace(/[\s().-]/g, '')
  const cc = countryCode.replace(/^\+/, '')
  let candidate: string
  if (v.startsWith('+')) candidate = v
  else if (v.startsWith('00')) candidate = '+' + v.slice(2)
  else if (!/^\d+$/.test(v)) return null
  else if (v.length > 10 && v.startsWith(cc)) candidate = '+' + v
  else candidate = '+' + cc + v.replace(/^0+/, '')
  return /^\+[1-9]\d{7,14}$/.test(candidate) ? candidate : null
}
const PHONE_ERROR = 'Enter a valid phone number, e.g. 98765 43210 or +971 50 123 4567.'
const WHATSAPP_ERROR = 'Enter a valid WhatsApp number, e.g. 98765 43210 or +971 50 123 4567.'
const WHATSAPP_NEEDS_PHONE = 'Enter a phone number, or untick "Same as phone number" and enter the WhatsApp number.'
const normalizePhone = (p: string | null | undefined) => {
  const digits = (p ?? '').replace(/\D/g, '')
  return digits.length < 7 ? null : digits.slice(-10)
}

interface Membership {
  id: string
  tenantId: string
  branchId: string | null
  role: string
  status: 'active' | 'invited' | 'suspended'
  createdOn: string
}

interface MockUser {
  id: string
  email: string
  memberships: Membership[]
  activeTenantId: string | null
  /** identity.platform_admins (no tenant access implied). */
  platformAdmin?: boolean
}

/** Level 1 onboarding / platform console (identity.tenant_signup_requests, invite_links, platform_list_tenants). */
interface MockSignup {
  id: string
  hospitalName: string
  timeZone: string
  contactName: string
  contactEmail: string
  phone: string
  city: string
  status: 'pending' | 'approved' | 'rejected'
  decisionReason: string | null
  decidedOn: string | null
  tenantId: string | null
  tenantCode: string | null
  createdOn: string
  possibleDuplicate?: boolean
  matchedHospitals?: string[]
}
interface MockPlatformTenant {
  id: string
  code: string
  name: string
  timeZone: string
  createdOn: string
  branchCount: number
  userCount: number
}
interface MockInviteLink {
  id: string
  tenantId: string
  tenantName: string
  email: string
  role: string
  branchId: string | null
  token: string
  status: 'pending' | 'claimed' | 'revoked'
  expiresOn: string
  createdOn: string
  claimedOn: string | null
}

export const OPERATOR_EMAIL = 'operator@medicore.example'
export const INVITEE_EMAIL = 'invitee@synthetic.example'

/** identity.hospital_name_key: lowercase, strip non-alnum, drop a trailing hospital/clinic suffix. */
function signupNameKey(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '')
    .replace(/(hospitals|hospital|clinics|clinic)+$/, '')
}

/** identity.phone_key: digits only; +91 or a leading 0 folds a 10-digit national number. */
function signupPhoneKey(phone: string): string {
  const digits = phone.replace(/[^0-9]/g, '')
  if (/^91\d{10}$/.test(digits)) return digits.slice(2)
  if (/^0\d{10}$/.test(digits)) return digits.slice(1)
  return digits
}


export interface RecordedCall {
  method: string
  url: string
  path: string
  body: unknown
  headers: Record<string, string>
}

/**
 * Injected failure for one matching API request (cold-start / gateway behaviour):
 * - status: answer with this status instead (e.g. 503 + Retry-After, like the YARP edge for a cold service)
 * - delayMs: answer late (then normally, unless status/abort/hang is set)
 * - abort: network error; hang: never answer (the client's own timeout fires)
 */
export interface Fault {
  method?: string
  path: string | RegExp
  /** How many matching requests to affect (default 1). */
  times?: number
  delayMs?: number
  status?: number
  headers?: Record<string, string>
  body?: unknown
  abort?: boolean
  hang?: boolean
}

/** The edge's answer for a cold or unreachable service (CTO decision). */
export const SERVICE_UNAVAILABLE: Pick<Fault, 'status' | 'headers' | 'body'> = {
  status: 503,
  headers: { 'Retry-After': '5' },
  body: { type: 'about:blank', title: 'Service Unavailable', status: 503, code: 'service_unavailable' },
}

let seq = 0
const uuid = (prefix: string) => `${prefix}${String(++seq).padStart(12, '0')}`.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12}).*$/, '$1-$2-$3-$4-$5')

const b64url = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url')

interface MockBill {
  id: string
  accountId: string
  patientId: string
  branchId: string
  status: 'draft' | 'finalized'
  billNo: string | null
  lines: { id: string; lineNo: number; serviceItemId: string; code: string; name: string; quantity: number; unitPricePaise: number; taxRateBp: number; netPaise: number; taxPaise: number; practitionerId: null }[]
  totalPaise: number
  duePaise: number
}

interface MockReceipt {
  id: string
  receiptNo: string
  kind: string
  amountPaise: number
  accountId: string
  tenders: { mode: string; amountPaise: number; reference: string | null }[]
  allocations: { billId: string; amountPaise: number }[]
}

interface MockApproval {
  id: string
  action: string
  status: string
  amountPaise: number
  percentBp: number
  requestedBy: string | null
  approverId: string | null
  subjectType: string
  subjectId: string
  note: string | null
}

interface MockSession {
  sessionId: string
  counterId: string
  cashierId: string
  status: string
  openingFloatPaise: number
  countedCashPaise: number | null
  expectedCashPaise: number
  variancePaise: number | null
  businessDate: string
  branchId: string
}

function earningsReport() {
  const move = { direction: 'down', pct: -12 }
  const card = {
    grossBilledPaise: 1038400, collectedPaise: 1038400, refundsPaise: 0, netEarningsPaise: 1038400, outstandingPaise: 0,
    discountPaise: 0, cgstPaise: 79200, sgstPaise: 79200, igstPaise: 0, billCount: 1, averageBillPaise: 1038400,
    visitCount: 1, doctorCount: 1, revenuePerVisitPaise: 1038400, revenuePerDoctorPaise: 1038400,
    collectionEfficiencyPct: 100, refundRatePct: 0, discountRatePct: 0,
    periodGrowthPct: -12, momGrowthPct: null, yoyGrowthPct: null,
    deltas: {
      grossBilled: move, collected: move, netEarnings: move, refunds: { direction: 'flat', pct: null }, billCount: move,
      averageBill: move, collectionEfficiency: move, refundRate: move, mom: move, yoy: move,
    },
  }
  return {
    from: '2026-04-01', to: '2026-04-30', grain: 'month', branchId: null, financialYear: null, quarter: null, level: 'tenant',
    tenant: card, focus: card,
    branches: [{
      branchId: ids.alphaMain, name: 'Alpha Main Campus', gstin: '36AABCU9603R1ZM', deleted: false, rank: 1, sharePct: 89.8,
      grossBilledPaise: 1038400, collectedPaise: 1038400, netEarningsPaise: 1038400, outstandingPaise: 0, billCount: 1,
      periodGrowthPct: -12, direction: 'down',
    }],
    trend: [{ bucket: '2026-04-01', grossBilledPaise: 1038400, collectedPaise: 1038400, netEarningsPaise: 1038400 }],
    doctors: [], services: [], paymentModes: [],
    ageing: { b0To30Paise: 0, b31To60Paise: 0, b61To90Paise: 0, b90PlusPaise: 0 },
    topBottom: { topBranch: null, bottomBranch: null, topDoctor: null, bottomDoctor: null },
    insights: ['Alpha Main Campus revenue down 12% vs last month'],
    gstr1: [{ gstin: '36AABCU9603R1ZM', month: '2026-04', b2cTaxablePaise: 880000, b2bTaxablePaise: 0, b2cCgstPaise: 79200, b2cSgstPaise: 79200, b2cIgstPaise: 0, b2bCgstPaise: 0, b2bSgstPaise: 0, b2bIgstPaise: 0, b2cInvoices: 1, b2bInvoices: 0, creditNoteCount: 0 }],
    gstr3b: [], hsn: [],
    sales: [{ invoiceNumber: 'AM-APR', date: '2026-04-10', party: 'Asha Synthetic-Alpha', supply: 'B2C', gstin: '36AABCU9603R1ZM', taxablePaise: 880000, cgstPaise: 79200, sgstPaise: 79200, igstPaise: 0, taxPaise: 158400, totalPaise: 1038400 }],
    creditNotes: [], refunds: [], receipts: [], dayEndCash: [], truncated: false,
  }
}

export class MockBackend {
  readonly calls: RecordedCall[] = []
  /** Pending injected faults, consumed in order (see Fault). */
  readonly faults: (Fault & { remaining: number })[] = []
  /** Number of GET /api/v1/warmup calls received. */
  warmups = 0
  readonly users = new Map<string, MockUser>()
  private refreshTokens = new Map<string, string>() // refresh token -> user id

  constructor() {
    const alphaAdmin = this.addUser('admin@alpha.example')
    alphaAdmin.memberships.push(this.membership(ids.alpha, null, 'tenant_admin', 'active'))
    const consultant = this.addUser('consultant@shared.example')
    consultant.memberships.push(this.membership(ids.alpha, null, 'doctor', 'active'), this.membership(ids.beta, null, 'doctor', 'active'))
    this.addUser('newcomer@synthetic.example')
    // Sprint 2 personas: branch-bound front desk, tenant-wide clinician.
    this.addUser('reception@alpha.example').memberships.push(this.membership(ids.alpha, ids.alphaMain, 'receptionist', 'active'))
    this.addUser('doctor@alpha.example').memberships.push(this.membership(ids.alpha, null, 'doctor', 'active'))
    this.addUser('billing@alpha.example').memberships.push(this.membership(ids.alpha, null, 'billing', 'active'))
    this.addUser('accounts@alpha.example').memberships.push(this.membership(ids.alpha, null, 'accountant', 'active'))
    // Level 1: the platform operator (no hospital membership) and an account invited by link.
    this.addUser(OPERATOR_EMAIL).platformAdmin = true
    this.addUser(INVITEE_EMAIL)
    this.signups.push(
      { id: '5a000000-0000-4000-8000-000000000001', hospitalName: 'Synthetic Orchid Hospital', timeZone: 'Asia/Dubai', contactName: 'Omar Synthetic', contactEmail: 'omar@orchid.example', phone: '+971 4 555 0100', city: 'Dubai', status: 'pending', decisionReason: null, decidedOn: null, tenantId: null, tenantCode: null, createdOn: '2026-10-18T06:15:00.000Z' },
      { id: '5a000000-0000-4000-8000-000000000002', hospitalName: 'Synthetic Lotus Clinic', timeZone: 'Asia/Kolkata', contactName: 'Asha Synthetic', contactEmail: 'asha@lotus.example', phone: '+91 20 5550 1234', city: 'Pune', status: 'pending', decisionReason: null, decidedOn: null, tenantId: null, tenantCode: null, createdOn: '2026-10-19T02:40:00.000Z' },
    )
    // Today's booked appointment for Asha with Dr. Rao (check-in flow).
    const today = branchToday()
    this.appointments.push({ id: 'a0000000-0000-4000-8000-000000000001', tenantId: ids.alpha, branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.asha, startsAt: branchInstant(today, '09:30'), endsAt: branchInstant(today, '09:45'), status: 'booked', reason: null, cancelReason: null })
    const shared = this.blankBill(patientIds.asha, ids.alphaMain)
    shared.status = 'finalized'
    shared.billNo = 'OPBDEMO000000001'
    shared.lines.push(this.consultLine())
    shared.totalPaise = 50000
    shared.duePaise = 50000
    this.mockBills.set(shared.id, shared)
    this.mockLinks.set('demo-token', { status: 'pending', channel: 'link', billId: shared.id, polls: 0 })
    this.mockApprovals.push({
      id: 'c0000000-0000-4000-8000-000000000001',
      action: 'discount',
      status: 'pending',
      amountPaise: 5000,
      percentBp: 1000,
      requestedBy: null,
      approverId: null,
      subjectType: 'bill',
      subjectId: shared.id,
      note: null,
    })
    this.mockSessions.push({
      sessionId: 'd0000000-0000-4000-8000-000000000001',
      counterId: 'd1000000-0000-4000-8000-000000000001',
      cashierId: '0a000000-0000-4000-8000-000000000002',
      status: 'closed',
      openingFloatPaise: 0,
      countedCashPaise: 50000,
      expectedCashPaise: 50000,
      variancePaise: 0,
      businessDate: today,
      branchId: ids.alphaMain,
    })
  }

  /** true = pre-v2 API: no embedded patient summary, `/practitioners?branchId=` → 400. */
  legacyApi = false
  /** Per-branch IANA zone overrides (default BRANCH_TZ). */
  readonly branchTimeZones = new Map<string, string>()
  branchZone(branchId: string) {
    const tenantId = Object.entries(tenants).find(([, t]) => t.branches.some((b) => b.id === branchId))?.[0]
    return this.branchTimeZones.get(branchId) ?? (tenantId ? this.tenantZone(tenantId) : BRANCH_TZ)
  }

  readonly patients: MockPatient[] = seedPatients()
  readonly mockBills = new Map<string, MockBill>()
  readonly mockLinks = new Map<string, { status: string; channel: string; billId: string; polls: number }>()
  readonly mockReceipts = new Map<string, MockReceipt>()
  readonly mockApprovals: MockApproval[] = []
  readonly mockSessions: MockSession[] = []
  /** Per instance (admin screens write to them). */
  readonly practitioners: MockPractitioner[] = seedPractitioners()
  readonly schedules: MockSchedule[] = seedSchedules()
  /** Hospital (tenant) zone; branches without an override in branchTimeZones follow it. */
  readonly tenantTimeZones = new Map<string, string>()
  tenantZone(tenantId: string) {
    return this.tenantTimeZones.get(tenantId) ?? BRANCH_TZ
  }
  /** Renamed hospitals/branches (admin screens). */
  readonly tenantNames = new Map<string, string>()
  /** patient.mrn_counters: per-tenant MRN sequence (seed MRNs use the legacy format). */
  readonly mrnCounters = new Map<string, number>()
  readonly branchNames = new Map<string, string>()
  /** Branches created through POST /branches in this instance (the seed list is shared). */
  readonly createdBranches: { id: string; name: string; code: string }[] = []
  readonly appointments: MockAppointment[] = []
  /** Latest booking time per patient (ms), for GET /patients?sort=recent. */
  readonly lastBooked = new Map<string, number>()
  readonly queue: MockQueueEntry[] = []
  /** Level 1 state (per instance). */
  readonly signups: MockSignup[] = []
  readonly platformTenants: MockPlatformTenant[] = []
  readonly inviteLinks: MockInviteLink[] = []
  readonly tenantStatus = new Map<string, { status: 'active' | 'suspended'; history: { fromStatus: string; toStatus: string; reason: string; changedOn: string; changedBy: string | null }[] }>()
  readonly branchState = new Map<string, { isActive: boolean; isDeleted: boolean }>()
  tenantIsActive(tenantId: string) {
    return (this.tenantStatus.get(tenantId)?.status ?? 'active') === 'active'
  }
  private tokenCounters = new Map<string, number>()

  /** Another desk books directly (to provoke a 409 in the UI). */
  bookDirectly(a: Omit<MockAppointment, 'id' | 'tenantId' | 'status' | 'reason' | 'cancelReason'>) {
    this.appointments.push({ ...a, id: uuid('a1000000'), tenantId: ids.alpha, status: 'booked', reason: null, cancelReason: null })
  }

  /** Another desk issues a token (for live-refresh checks). */
  issueToken(branchId: string, patientId: string, practitionerId: string | null = null): MockQueueEntry {
    const today = branchToday()
    const key = `${branchId}|${today}`
    const tokenNo = (this.tokenCounters.get(key) ?? 0) + 1
    this.tokenCounters.set(key, tokenNo)
    const tenantId = Object.entries(tenants).find(([, t]) => t.branches.some((b) => b.id === branchId))![0]
    const entry: MockQueueEntry = { id: uuid('9e000000'), tenantId, branchId, queueDate: today, tokenNo, patientId, appointmentId: null, practitionerId, status: 'waiting', checkedInAt: new Date().toISOString(), calledAt: null, completedAt: null, cancelledAt: null }
    this.queue.push(entry)
    return entry
  }

  addUser(email: string): MockUser {
    const user: MockUser = { id: uuid('0a000000'), email, memberships: [], activeTenantId: null }
    this.users.set(email, user)
    return user
  }

  membership(tenantId: string, branchId: string | null, role: string, status: Membership['status']): Membership {
    return { id: uuid('cc000000'), tenantId, branchId, role, status, createdOn: new Date(Date.now() + seq).toISOString() }
  }

  /** Invite like identity.add_member(): 'invited', never displaces the default tenant. */
  invite(email: string, tenantId: string, role: string, branchId: string | null = null) {
    const user = this.users.get(email)
    if (!user || user.memberships.some((m) => m.tenantId === tenantId && m.role === role && m.branchId === branchId)) return
    user.memberships.push(this.membership(tenantId, branchId, role, 'invited'))
  }

  /** Server-side context change (e.g. the user switched hospital on another device). */
  setActiveTenant(email: string, tenantId: string) {
    this.users.get(email)!.activeTenantId = tenantId
  }

  /** identity.resolve_active_context: persisted preference, else oldest ACTIVE membership. */
  resolvedTenant(user: MockUser): string | null {
    // Suspended hospitals never resolve (my_tenant_grant_v1 requires tenants.status = 'active').
    const active = user.memberships.filter((m) => m.status === 'active' && this.tenantIsActive(m.tenantId)).sort((a, b) => a.createdOn.localeCompare(b.createdOn))
    const pref = active.find((m) => m.tenantId === user.activeTenantId)
    const tenant = pref?.tenantId ?? active[0]?.tenantId ?? null
    if (tenant) user.activeTenantId = tenant // first resolution is persisted
    return tenant
  }

  private session(user: MockUser) {
    const now = Math.floor(Date.now() / 1000)
    const claims = { sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', iat: now, exp: now + 3600, session_id: user.id, tenant_id: this.resolvedTenant(user) }
    const refresh = `rt-${uuid('ee000000')}`
    this.refreshTokens.set(refresh, user.id)
    return {
      access_token: `${b64url({ alg: 'ES256', typ: 'JWT' })}.${b64url(claims)}.mock-signature`,
      token_type: 'bearer',
      expires_in: 3600,
      expires_at: now + 3600,
      refresh_token: refresh,
      user: { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, app_metadata: { provider: 'email' }, user_metadata: {}, created_at: new Date(0).toISOString() },
    }
  }

  private userFromRequest(request: Request): MockUser | null {
    const token = (request.headers()['authorization'] ?? '').replace(/^Bearer\s+/i, '')
    const payload = token.split('.')[1]
    if (!payload) return null
    const sub = JSON.parse(Buffer.from(payload, 'base64url').toString()).sub
    return [...this.users.values()].find((u) => u.id === sub) ?? null
  }

  /** Injects a failure for the next `times` (default 1) matching requests. */
  fault(fault: Fault) {
    this.faults.push({ ...fault, remaining: fault.times ?? 1 })
  }

  private takeFault(method: string, path: string): Fault | null {
    const f = this.faults.find((x) => x.remaining > 0 && (!x.method || x.method === method) && (typeof x.path === 'string' ? x.path === path : x.path.test(path)))
    if (!f) return null
    f.remaining -= 1
    return f
  }

  /** Installs on the whole browser context so tabs opened later are mocked too. */
  async install(target: BrowserContext | Page) {
    await target.route(`${MOCK_AUTH_URL}/**`, (route) => this.handleAuth(route))
    await target.route(/\/(api\/v1|health)\//, (route) => this.handleApi(route))
  }

  private record(request: Request) {
    const url = new URL(request.url())
    let body: unknown
    try {
      body = request.postDataJSON()
    } catch {
      body = request.postData()
    }
    this.calls.push({ method: request.method(), url: request.url(), path: url.pathname, body, headers: request.headers() })
  }

  private async handleAuth(route: Route) {
    const request = route.request()
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS' }
    if (request.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors })
    this.record(request)
    const url = new URL(request.url())
    const json = (status: number, body?: unknown) => route.fulfill({ status, headers: { ...cors, 'content-type': 'application/json' }, body: body === undefined ? '' : JSON.stringify(body) })
    const body = (request.postDataJSON() ?? {}) as Record<string, string>
    if (url.pathname === '/auth/v1/token' && url.searchParams.get('grant_type') === 'password') {
      const user = this.users.get(String(body.email).toLowerCase())
      if (!user || body.password !== PASSWORD) return json(400, { error_code: 'invalid_credentials', msg: 'Invalid login credentials' })
      return json(200, this.session(user))
    }
    if (url.pathname === '/auth/v1/token' && url.searchParams.get('grant_type') === 'refresh_token') {
      const userId = this.refreshTokens.get(body.refresh_token ?? '')
      const user = [...this.users.values()].find((u) => u.id === userId)
      if (!user) return json(400, { error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token' })
      this.refreshTokens.delete(body.refresh_token!)
      return json(200, this.session(user))
    }
    if (url.pathname === '/auth/v1/logout') return json(204)
    if (url.pathname === '/auth/v1/user') {
      const user = this.userFromRequest(request)
      return user ? json(200, { id: user.id, email: user.email, aud: 'authenticated' }) : json(401, { msg: 'invalid JWT' })
    }
    return json(404, { msg: 'Not found' })
  }

  private blankBill(patientId: string, branchId: string): MockBill {
    return {
      id: uuid('c2'),
      accountId: uuid('c4'),
      patientId,
      branchId,
      status: 'draft',
      billNo: null,
      lines: [],
      totalPaise: 0,
      duePaise: 0,
    }
  }

  private consultLine() {
    return {
      id: uuid('c5'),
      lineNo: 1,
      serviceItemId: 'c6000000-0000-4000-8000-000000000001',
      code: 'CONSULT',
      name: 'OP consultation',
      quantity: 1,
      unitPricePaise: 50000,
      taxRateBp: 0,
      netPaise: 50000,
      taxPaise: 0,
      practitionerId: null,
    }
  }

  private billJson(bill: MockBill) {
    return {
      id: bill.id,
      billNo: bill.billNo,
      status: bill.status,
      billKind: 'final',
      payerType: 'self',
      accountId: bill.accountId,
      patientId: bill.patientId,
      branchId: bill.branchId,
      lines: bill.lines,
      discounts: [],
      netPaise: bill.totalPaise,
      taxPaise: 0,
      discountPaise: 0,
      exactPaise: bill.totalPaise,
      roundOffPaise: 0,
      totalPaise: bill.totalPaise,
      duePaise: bill.duePaise,
    }
  }

  private watchQr(bill: MockBill) {
    for (const link of this.mockLinks.values()) {
      if (link.billId === bill.id && link.channel === 'qr' && link.status !== 'paid') {
        link.polls += 1
        if (link.polls >= 2) {
          link.status = 'paid'
          bill.duePaise = 0
        }
      }
    }
  }

  private publicBill(token: string) {
    const link = this.mockLinks.get(token)
    if (!link) return null
    const bill = this.mockBills.get(link.billId)
    if (!bill) return null
    this.watchQr(bill)
    return { ...this.billJson(bill), linkStatus: link.status, channel: link.channel }
  }

  private billingResponse(method: string, path: string, url: URL, body: Record<string, unknown>, idempotencyKey: string | null): { status: number; body: unknown } | null {
    if (method === 'POST' && path === '/api/v1/accounts/from-appointment') {
      const bill = this.blankBill(String(body.patientId ?? patientIds.asha), ids.alphaMain)
      bill.lines.push(this.consultLine())
      bill.totalPaise = 50000
      bill.duePaise = 50000
      this.mockBills.set(bill.id, bill)
      return { status: 200, body: this.billJson(bill) }
    }
    if (method === 'GET' && path === '/api/v1/bills') {
      const status = url.searchParams.get('status')
      const rows = [...this.mockBills.values()]
        .filter((bill) => !status || bill.status === status)
        .map((bill) => ({ id: bill.id, billNo: bill.billNo, status: bill.status, billKind: 'final', patientId: bill.patientId, branchId: bill.branchId, totalPaise: bill.totalPaise, duePaise: bill.duePaise, createdOn: '2026-10-25T00:00:00Z' }))
      return { status: 200, body: rows }
    }
    const summary = /^\/api\/v1\/accounts\/([^/]+)\/summary$/.exec(path)
    if (method === 'GET' && summary) {
      return { status: 200, body: { patientId: summary[1], advancePaise: 0, accounts: [], bills: [] } }
    }
    if (method === 'POST' && path === '/api/v1/counter-sessions/ensure') {
      return { status: 200, body: { id: 'c1000000-0000-4000-8000-000000000001', businessDate: '2026-10-23', opened: true } }
    }
    if (method === 'GET' && path === '/api/v1/counter-sessions/open') {
      return { status: 200, body: { id: null } }
    }
    if (method === 'POST' && path === '/api/v1/accounts') {
      const bill = this.blankBill(String(body.patientId), String(body.branchId))
      this.mockBills.set(bill.id, bill)
      return { status: 200, body: this.billJson(bill) }
    }
    const lines = /^\/api\/v1\/bills\/([^/]+)\/lines$/.exec(path)
    if (method === 'POST' && lines) {
      const bill = this.mockBills.get(lines[1]!)
      if (!bill) return { status: 404, body: { title: 'Not found', status: 404 } }
      bill.lines.push(this.consultLine())
      bill.totalPaise = 50000
      bill.duePaise = 50000
      return { status: 200, body: this.billJson(bill) }
    }
    const finalize = /^\/api\/v1\/bills\/([^/]+)\/finalize$/.exec(path)
    if (method === 'POST' && finalize) {
      const bill = this.mockBills.get(finalize[1]!)
      if (!bill) return { status: 404, body: { title: 'Not found', status: 404 } }
      bill.status = 'finalized'
      bill.billNo = 'OPB0000000000001'
      return { status: 200, body: this.billJson(bill) }
    }
    const billPath = /^\/api\/v1\/bills\/([^/]+)$/.exec(path)
    if (method === 'GET' && billPath) {
      const bill = this.mockBills.get(billPath[1]!)
      if (!bill) return { status: 404, body: { title: 'Not found', status: 404 } }
      this.watchQr(bill)
      return { status: 200, body: this.billJson(bill) }
    }
    const link = /^\/api\/v1\/bills\/([^/]+)\/payment-links$/.exec(path)
    if (method === 'POST' && link) {
      const bill = this.mockBills.get(link[1]!)
      if (!bill) return { status: 404, body: { title: 'Not found', status: 404 } }
      const order = uuid('c7').replace(/-/g, '')
      const channel = String(body.channel ?? 'link')
      this.mockLinks.set(order, { status: 'pending', channel, billId: bill.id, polls: 0 })
      return {
        status: 200,
        body: {
          id: uuid('c8'),
          providerOrderId: order,
          channel,
          path: `/api/v1/billing-public/links/${order}`,
          upiUri: `upi://pay?pa=sandbox@medicore&pn=MediCore%20Sandbox&am=${(bill.duePaise / 100).toFixed(2)}&tr=${order}&cu=INR`,
          shareStatus: channel === 'whatsapp' || channel === 'sms' ? 'queued' : undefined,
        },
      }
    }
    if (method === 'POST' && path === '/api/v1/payments') {
      if (idempotencyKey && this.mockReceipts.has(idempotencyKey)) return { status: 200, body: this.mockReceipts.get(idempotencyKey) }
      const allocations = (body.allocations as { billId?: string; amountPaise?: number }[] | undefined) ?? []
      const bill = allocations[0]?.billId ? this.mockBills.get(allocations[0].billId) : undefined
      if (bill) bill.duePaise = 0
      const amount = allocations[0]?.amountPaise ?? bill?.totalPaise ?? 0
      const receipt: MockReceipt = {
        id: uuid('c9'),
        receiptNo: 'RCP000000000001',
        kind: 'payment',
        amountPaise: amount,
        accountId: bill?.accountId ?? String(body.accountId ?? ''),
        tenders: ((body.tenders as { mode?: string; amountPaise?: number }[] | undefined) ?? []).map((t) => ({
          mode: String(t.mode),
          amountPaise: Number(t.amountPaise),
          reference: null,
        })),
        allocations: allocations.map((a) => ({ billId: String(a.billId), amountPaise: Number(a.amountPaise) })),
      }
      if (idempotencyKey) this.mockReceipts.set(idempotencyKey, receipt)
      return { status: 200, body: receipt }
    }
    const receipt = /^\/api\/v1\/receipts\/([^/]+)$/.exec(path)
    if (method === 'GET' && receipt) {
      const found = [...this.mockReceipts.values()].find((item) => item.id === receipt[1])
      if (!found) return { status: 404, body: { title: 'Not found', status: 404 } }
      return { status: 200, body: found }
    }
    if (method === 'GET' && path === '/api/v1/approvals') {
      const status = url.searchParams.get('status')
      return { status: 200, body: this.mockApprovals.filter((item) => !status || item.status === status) }
    }
    const decide = /^\/api\/v1\/approvals\/([^/]+)\/decide$/.exec(path)
    if (method === 'POST' && decide) {
      const item = this.mockApprovals.find((row) => row.id === decide[1])
      if (!item) return { status: 404, body: { title: 'Not found', status: 404 } }
      item.status = String(body.status)
      item.note = body.note ? String(body.note) : null
      return { status: 200, body: { approvalId: item.id, status: item.status } }
    }
    if (method === 'GET' && path === '/api/v1/billing-reports/day-end') {
      const branchId = url.searchParams.get('branchId')
      const date = url.searchParams.get('date')
      return {
        status: 200,
        body: this.mockSessions.filter((session) => session.branchId === branchId && session.businessDate === date),
      }
    }
    const reconcile = /^\/api\/v1\/counter-sessions\/([^/]+)\/reconcile$/.exec(path)
    if (method === 'POST' && reconcile) {
      const session = this.mockSessions.find((row) => row.sessionId === reconcile[1])
      if (!session || session.status !== 'closed') return { status: 404, body: { title: 'Not found', status: 404 } }
      session.status = 'reconciled'
      return { status: 200, body: { id: session.sessionId, status: 'reconciled' } }
    }
    return null
  }

  private async handleApi(route: Route) {
    const request = route.request()
    this.record(request)
    const url = new URL(request.url())
    const method = request.method()
    const path = url.pathname
    const fault = this.takeFault(method, path)
    if (fault) {
      if (fault.delayMs) await new Promise((resolve) => setTimeout(resolve, fault.delayMs))
      if (fault.hang) return // never answered: the client times out
      if (fault.abort) return route.abort('connectionrefused').catch(() => {})
      if (fault.status) {
        return route
          .fulfill({ status: fault.status, headers: { 'content-type': 'application/problem+json', ...fault.headers }, body: fault.body === undefined ? '' : JSON.stringify(fault.body) })
          .catch(() => {}) // the client may have given up already
      }
    }
    const reply = (status: number, body?: unknown, tenant?: string | null) =>
      route.fulfill({
        status,
        headers: { 'content-type': 'application/json', ...(tenant ? { 'X-Hms-Tenant': tenant } : {}) },
        body: body === undefined || status === 204 ? '' : JSON.stringify(body),
      })

    if (path === '/health/live') return reply(200, { status: 'Healthy' })
    // Dedicated, unauthenticated warm-up (wakes the edge and services); the client ignores the result.
    if (method === 'GET' && path === '/api/v1/warmup') {
      this.warmups += 1
      return reply(204)
    }
    const publicBill = /^\/api\/v1\/billing-public\/links\/([^/]+)$/.exec(path)
    if (method === 'GET' && publicBill) {
      const linked = this.publicBill(publicBill[1]!)
      if (!linked) return reply(404, { title: 'Not found', status: 404, code: 'not_found' })
      return reply(200, linked)
    }
    if (path.startsWith('/api/v1/public/')) {
      let pub: Record<string, unknown> = {}
      try {
        pub = (request.postDataJSON() ?? {}) as Record<string, unknown>
      } catch {
        pub = {}
      }
      if (method === 'POST' && path === '/api/v1/public/hospital-signups') {
        const accepted = { message: 'Thank you. If the details are valid, our team will review your request and contact you.' }
        if (pub.website) return reply(202, accepted) // honeypot: dropped silently
        const email = String(pub.contactEmail ?? '').trim().toLowerCase()
        const registered =
          [...this.users.values()].some(
            (u) =>
              u.email.toLowerCase() === email &&
              u.memberships.some((m) => m.role === 'tenant_admin' && m.status === 'active' && this.tenantIsActive(m.tenantId)),
          ) || this.signups.some((s) => s.status === 'approved' && s.contactEmail === email)
        if (registered) {
          return reply(409, {
            title: 'Already registered',
            status: 409,
            code: 'email_registered',
            detail: 'This email is already registered. Please sign in or contact support.',
          })
        }
        if (!this.signups.some((x) => x.status === 'pending' && x.contactEmail === email)) {
          const hospitalName = String(pub.hospitalName)
          const phone = String(pub.phone)
          const nameKey = signupNameKey(hospitalName)
          const phoneKey = signupPhoneKey(phone)
          const matched = new Set<string>()
          for (const other of this.signups) {
            if (other.status !== 'pending') continue
            const sameName = nameKey !== '' && signupNameKey(other.hospitalName) === nameKey
            const samePhone = phoneKey !== '' && signupPhoneKey(other.phone) === phoneKey
            if (!sameName && !samePhone) continue
            matched.add(other.hospitalName)
            other.possibleDuplicate = true
            other.matchedHospitals = [...new Set([...(other.matchedHospitals ?? []), hospitalName])]
          }
          for (const hospital of Object.values(tenants)) {
            if (nameKey !== '' && signupNameKey(hospital.name) === nameKey) matched.add(hospital.name)
          }
          this.signups.push({
            id: uuid('5a100000'),
            hospitalName,
            timeZone: String(pub.timeZone),
            contactName: String(pub.contactName),
            contactEmail: email,
            phone,
            city: String(pub.city),
            status: 'pending',
            decisionReason: null,
            decidedOn: null,
            tenantId: null,
            tenantCode: null,
            createdOn: new Date().toISOString(),
            possibleDuplicate: matched.size > 0,
            matchedHospitals: [...matched],
          })
        }
        return reply(202, accepted)
      }
      const pre = /^\/api\/v1\/public\/invites\/([0-9a-f]{64})$/.exec(path)
      if (method === 'GET' && pre) {
        const link = this.inviteLinks.find((l) => l.token === pre[1] && l.status === 'pending' && l.expiresOn > new Date().toISOString())
        if (!link) return reply(404, { title: 'Not found', status: 404, code: 'not_found' })
        const [local, domain] = link.email.split('@')
        return reply(200, { tenantName: link.tenantName, role: link.role, branchName: link.branchId ? (tenants[link.tenantId]?.branches.find((b) => b.id === link.branchId)?.name ?? null) : null, emailHint: `${local!.slice(0, 1)}***@${domain}`, expiresOn: link.expiresOn })
      }
      return reply(404, { title: 'Not found', status: 404 })
    }
    const user = this.userFromRequest(request)
    if (!user) return reply(401, { title: 'Unauthorized', status: 401 })
    const tenant = this.resolvedTenant(user)
    const active = user.memberships.filter((m) => m.status === 'active')
    const inTenant = active.filter((m) => m.tenantId === tenant)
    const roles = [...new Set(inTenant.map((m) => m.role))]
    // null = tenant-wide (some membership has no branch); else the set of bound branches.
    const scopedBranches = inTenant.some((m) => m.branchId === null) ? null : new Set(inTenant.map((m) => m.branchId!))
    const rolesAt = (branchId: string) => [...new Set(inTenant.filter((m) => m.branchId === null || m.branchId === branchId).map((m) => m.role))]
    const canAccessBranch = (branchId: string) => !!tenant && tenants[tenant]!.branches.some((b) => b.id === branchId) && (!scopedBranches || scopedBranches.has(branchId))
    let body: Record<string, unknown> = {}
    try {
      body = (request.postDataJSON() ?? {}) as Record<string, unknown>
    } catch {
      body = {}
    }
    if (path === '/api/v1/billing-reports/earnings' || path === '/api/v1/billing-reports/earnings/export') {
      const allowed = roles.includes('tenant_admin') || roles.includes('billing') || roles.includes('accountant')
      if (!allowed) return reply(403, { title: 'Forbidden', status: 403, code: 'forbidden' })
      if (path.endsWith('/export')) {
        const format = (url.searchParams.get('format') ?? 'csv').toLowerCase()
        if (format === 'xlsx') {
          return route.fulfill({
            status: 200,
            headers: {
              'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'content-disposition': 'attachment; filename="earnings-accounts.xlsx"',
            },
            body: 'PK\u0003\u0004synthetic',
          })
        }
        return route.fulfill({
          status: 200,
          headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="earnings-sales.csv"' },
          body: 'Invoice number,Date\nAM-APR,2026-04-10\n',
        })
      }
      return reply(200, earningsReport(), tenant)
    }
    const billed = this.billingResponse(method, path, url, body, request.headers()['idempotency-key'] ?? null)
    if (billed) return reply(billed.status, billed.body, tenant)

    // Tenant-independent endpoints (work for a signed-in user with no tenant).
    if (method === 'GET' && path === '/api/v1/me') {
      return reply(
        200,
        {
          userId: user.id,
          email: user.email,
          activeTenantId: tenant,
          activeBranchId: scopedBranches && scopedBranches.size === 1 ? [...scopedBranches][0] : null,
          roles,
          accessibleBranches: tenant ? tenants[tenant]!.branches.filter((b) => !scopedBranches || scopedBranches.has(b.id)).map(({ id, name }) => ({ id, name, timeZone: this.branchZone(id) })) : [],
          memberships: active.filter((m) => this.tenantIsActive(m.tenantId)).map((m) => ({ tenantId: m.tenantId, tenantName: this.tenantNames.get(m.tenantId) ?? tenants[m.tenantId]!.name, branchId: m.branchId, branchName: null, role: m.role })),
          isPlatformAdmin: user.platformAdmin === true,
        },
        tenant,
      )
    }
    // Claim an invite link (signed in; the account email must match). Tenant-independent.
    if (method === 'POST' && path === '/api/v1/me/invite-links/claim') {
      const link = this.inviteLinks.find((l) => l.token === body.token && l.status === 'pending')
      if (!link || !tenants[link.tenantId]) return reply(404, { title: 'Not found', status: 404, code: 'not_found' })
      if (link.email !== user.email) return reply(403, { title: 'Forbidden', status: 403, code: 'invite_email_mismatch' })
      if (!user.memberships.some((m) => m.tenantId === link.tenantId && m.role === link.role && m.branchId === link.branchId)) {
        user.memberships.push(this.membership(link.tenantId, link.branchId, link.role, 'active'))
      }
      Object.assign(link, { status: 'claimed', claimedOn: new Date().toISOString() })
      return reply(200, { tenantId: link.tenantId, tenantName: link.tenantName, role: link.role, branchId: link.branchId })
    }
    // Platform console (identity service): is_platform_admin() or 403; metadata only, no tenant access.
    if (path.startsWith('/api/v1/platform/')) {
      if (!user.platformAdmin) return reply(403, { title: 'Forbidden', status: 403, code: 'forbidden' })
      return this.handlePlatform(method, path, url, body, user, reply)
    }
    if (method === 'GET' && path === '/api/v1/me/invitations') {
      const invitations = user.memberships
        .filter((m) => m.status === 'invited')
        .map((m) => ({ membershipId: m.id, tenantId: m.tenantId, tenantName: tenants[m.tenantId]!.name, branchId: m.branchId, role: m.role, invitedAt: m.createdOn }))
      return reply(200, invitations, tenant)
    }
    const accept = /^\/api\/v1\/me\/invitations\/([^/]+)\/accept$/.exec(path)
    if (method === 'POST' && accept) {
      const membership = user.memberships.find((m) => m.id === accept[1] && m.status === 'invited')
      if (!membership) return reply(404, { title: 'Not found', status: 404 }, tenant)
      membership.status = 'active'
      return reply(204, undefined, tenant)
    }
    if (method === 'POST' && path === '/api/v1/me/context') {
      if (!active.some((m) => m.tenantId === body.tenantId)) return reply(403, { title: 'Forbidden', status: 403 }, tenant)
      user.activeTenantId = String(body.tenantId)
      return reply(204, undefined, tenant)
    }

    if (!tenant) return reply(403, { title: 'No active hospital', status: 403 })
    const REG_READ = ['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']
    // RBAC (ADR 0001): patient create/edit and booking/reschedule/cancel = front office only
    const REG_WRITE = ['tenant_admin', 'receptionist']
    const NO_SHOW = ['tenant_admin', 'receptionist', 'nurse', 'doctor']
    const QUEUE_READ = ['tenant_admin', 'doctor', 'nurse', 'receptionist']
    const FRONT_DESK = ['tenant_admin', 'receptionist', 'nurse']
    const has = (allowed: string[], held: string[] = roles) => held.some((r) => allowed.includes(r))
    const problem = (status: number, code?: string, extra: Record<string, unknown> = {}) => reply(status, { title: code ?? 'Error', status, ...(code ? { code } : {}), ...extra }, tenant)
    const notFound = () => problem(404, 'not_found')
    const forbidden = () => problem(403, 'forbidden')

    const livePatients = this.patients.filter((p) => p.tenantId === tenant && !p.deletedAt)
    // Level 1: phones[] + derived whatsappSameAsPhone (patient.patient_phones); the WhatsApp choice itself is internal.
    const phonesOf = (p: MockPatient) => [
      ...(p.phone ? [{ number: p.phone, isPrimary: true, isWhatsapp: p.whatsapp === 'same' }] : []),
      ...(p.whatsapp && p.whatsapp !== 'same' ? [{ number: p.whatsapp, isPrimary: false, isWhatsapp: true }] : []),
    ]
    const dto = ({ tenantId: _t, email: _e, whatsapp: _w, ...p }: MockPatient) => p
    const detailDto = (p: MockPatient) => {
      const { tenantId: _t, whatsapp: _w, ...rest } = p
      return { ...rest, phones: phonesOf(p), whatsappSameAsPhone: !!p.phone && p.whatsapp === 'same' }
    }
    const validationError = (errors: Record<string, string[]>) => reply(400, { title: 'Validation', status: 400, errors }, tenant)
    /** Like PatientPhones.ResolveWhatsapp: undefined = no change requested. */
    const resolveWhatsapp = (input: unknown, rawPhone: unknown, phone: string | null, errors: Record<string, string[]>): MockPatient['whatsapp'] => {
      if (input == null || typeof input !== 'object') return null
      const w = input as { sameAsPhone?: boolean; number?: string }
      if (w.sameAsPhone) {
        if (!phone && !(typeof rawPhone === 'string' && rawPhone.trim())) errors.whatsapp = [WHATSAPP_NEEDS_PHONE]
        return phone ? 'same' : null
      }
      if (!w.number?.trim()) return null
      const e164 = toE164(w.number)
      if (!e164) {
        errors.whatsapp = [WHATSAPP_ERROR]
        return null
      }
      return e164 === phone ? 'same' : e164
    }
    const page = (items: unknown[]) => ({ items, page: 1, pageSize: 25, totalCount: items.length })
    const patientMatch = /^\/api\/v1\/patients\/(?!stats$)([^/]+)$/.exec(path)
    const restoreMatch = /^\/api\/v1\/patients\/([^/]+)\/restore$/.exec(path)

    if (method === 'GET' && path === '/api/v1/patients') {
      if (url.searchParams.has('search')) {
        return reply(400, { title: 'Validation', status: 400, errors: { search: ['The search query parameter is no longer supported. Use POST /api/v1/patients/search with a JSON body.'] } }, tenant)
      }
      const sort = url.searchParams.get('sort')
      if (sort && sort !== 'name' && sort !== 'recent') return validationError({ sort: ["sort must be 'name' (default) or 'recent'."] })
      if (sort === 'recent') {
        // Like the API: the later of registration and latest booking, newest first (seed rows count as old).
        const at = (p: MockPatient) => Math.max(p.createdOn ? Date.parse(p.createdOn) : 0, this.lastBooked.get(p.id) ?? 0)
        return reply(200, page([...livePatients].sort((a, b) => at(b) - at(a)).map(dto)), tenant)
      }
      return reply(200, page(livePatients.map(dto)), tenant)
    }
    if (method === 'POST' && path === '/api/v1/patients/search') {
      if (!has(REG_READ)) return forbidden()
      const term = String(body.search ?? '').trim()
      if (term.length > 100) return reply(400, { title: 'Validation', status: 400, errors: { search: ['Search term must be at most 100 characters.'] } }, tenant)
      if (body.includeDeleted && !roles.includes('tenant_admin')) return forbidden()
      if (body.phone !== undefined && !normalizePhone(String(body.phone))) return reply(400, { title: 'Validation', status: 400, errors: { phone: ['Enter at least 7 digits.'] } }, tenant)
      const t = term.toLowerCase()
      const pool = this.patients.filter((p) => p.tenantId === tenant && (body.includeDeleted || !p.deletedAt))
      const hits = pool.filter(
        (p) =>
          (!t || [p.mrn, p.firstName, p.lastName].some((v) => v.toLowerCase().includes(t))) &&
          (body.phone === undefined || phonesOf(p).some((x) => normalizePhone(x.number) === normalizePhone(String(body.phone)))) &&
          (body.dateOfBirth === undefined || p.dateOfBirth === body.dateOfBirth),
      )
      return reply(200, page(hits.map(dto)), tenant)
    }
    if (method === 'POST' && path === '/api/v1/patients/duplicates') {
      if (!has(REG_WRITE)) return forbidden()
      const norm = (v: unknown) => String(v ?? '').trim().toLowerCase()
      const candidates = livePatients
        .map((p) => {
          const reasons: string[] = []
          const names = norm(body.firstName) !== '' && norm(body.lastName) !== '' && norm(p.firstName) === norm(body.firstName) && norm(p.lastName) === norm(body.lastName)
          if (names && body.dateOfBirth && p.dateOfBirth && p.dateOfBirth === body.dateOfBirth) reasons.push('name_dob')
          else if (names && (!body.dateOfBirth || !p.dateOfBirth)) reasons.push('name')
          if (normalizePhone(body.phone as string) && phonesOf(p).some((x) => normalizePhone(x.number) === normalizePhone(body.phone as string))) reasons.push('phone')
          if (norm(body.email) && norm(p.email) === norm(body.email)) reasons.push('email')
          return { p, reasons }
        })
        .filter((x) => x.reasons.length > 0 && x.p.id !== body.excludePatientId)
        .map(({ p, reasons }) => ({ id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName, dateOfBirth: p.dateOfBirth, phone: p.phone, registeredBranchId: p.registeredBranchId, matchReasons: reasons }))
      return reply(200, { candidates }, tenant)
    }
    // Like CreatePatientValidator: DOB ≤ today in the registered branch's time zone.
    const dobInFuture = (dob: unknown, branchId: string) => typeof dob === 'string' && dob > todayIn(this.branchZone(branchId))
    const dobProblem = () => reply(400, { title: 'Validation', status: 400, errors: { dateOfBirth: ['Date of birth cannot be in the future.'] } }, tenant)
    if (method === 'POST' && path === '/api/v1/patients') {
      if (!has(REG_WRITE, rolesAt(String(body.registeredBranchId)))) return forbidden()
      if (dobInFuture(body.dateOfBirth, String(body.registeredBranchId))) return dobProblem()
      // Any client `mrn` is ignored: the MRN comes from a per-tenant counter (<TENANT CODE>-<6 digits>).
      const errors: Record<string, string[]> = {}
      const phone = toE164(body.phone)
      if (typeof body.phone === 'string' && body.phone.trim() && !phone) errors.phone = [PHONE_ERROR]
      const whatsapp = resolveWhatsapp(body.whatsapp, body.phone, phone, errors)
      if (Object.keys(errors).length) return validationError(errors)
      const hard = ['phone', 'email', 'abha']
      const dupes = livePatients.flatMap((p) => {
        const reasons: string[] = []
        const norm = (v: unknown) => String(v ?? '').trim().toLowerCase()
        const names = norm(body.firstName) && norm(body.lastName) && norm(p.firstName) === norm(body.firstName) && norm(p.lastName) === norm(body.lastName)
        if (names && body.dateOfBirth && p.dateOfBirth && p.dateOfBirth === body.dateOfBirth) reasons.push('name_dob')
        else if (names && (!body.dateOfBirth || !p.dateOfBirth)) reasons.push('name')
        if (phone && phonesOf(p).some((x) => normalizePhone(x.number) === normalizePhone(phone))) reasons.push('phone')
        if (norm(body.email) && norm(p.email) === norm(body.email)) reasons.push('email')
        return reasons
      })
      if (dupes.some((r) => hard.includes(r))) return problem(409, 'duplicate_patient', { detail: 'Another patient in this hospital already has this email, phone number, or ABHA number.' })
      if (dupes.some((r) => r === 'name' || r === 'name_dob') && !String(body.duplicateOverrideReason ?? '').trim()) {
        return problem(409, 'duplicate_name_confirmation', { detail: 'A patient with this name already exists. Record why this is a different person.' })
      }
      const next = (this.mrnCounters.get(tenant) ?? 0) + 1
      this.mrnCounters.set(tenant, next)
      const mrn = `${tenant === ids.alpha ? 'ALPHA' : 'BETA'}-${String(next).padStart(6, '0')}`
      const created: MockPatient = { id: uuid('ab000000'), tenantId: tenant, mrn, firstName: String(body.firstName), lastName: String(body.lastName), dateOfBirth: (body.dateOfBirth as string) ?? null, sex: String(body.sex ?? 'unknown'), registeredBranchId: String(body.registeredBranchId), phone, whatsapp, email: (body.email as string) ?? null, deletedAt: null, createdOn: new Date().toISOString() }
      this.patients.push(created)
      return reply(201, { ...detailDto(created), duplicateWarnings: [] }, tenant)
    }
    if (patientMatch) {
      const patient = livePatients.find((p) => p.id === patientMatch[1])
      if (method === 'GET') {
        if (!has(REG_READ)) return forbidden()
        return patient ? reply(200, detailDto(patient), tenant) : notFound()
      }
      if (!patient) return notFound()
      if (method === 'PATCH') {
        if (!has(REG_WRITE)) return forbidden()
        if (body.registeredBranchId && !tenants[tenant]!.branches.some((b) => b.id === body.registeredBranchId)) return notFound()
        if ('mrn' in body && String(body.mrn).toUpperCase() !== patient.mrn.toUpperCase())
          return validationError({ mrn: ['The MRN is generated by the system and cannot be changed.'] })
        if (dobInFuture(body.dateOfBirth, String(body.registeredBranchId ?? patient.registeredBranchId))) return dobProblem()
        const errors: Record<string, string[]> = {}
        const { mrn: _m, phone: rawPhone, whatsapp: rawWhatsapp, ...rest } = body
        const phone = 'phone' in body ? toE164(rawPhone) : patient.phone
        if (typeof rawPhone === 'string' && rawPhone.trim() && !phone) errors.phone = [PHONE_ERROR]
        // No whatsapp in the patch: "same" follows the phone, a separate number is kept.
        const whatsapp = 'whatsapp' in body ? resolveWhatsapp(rawWhatsapp, rawPhone, phone, errors) : patient.whatsapp === 'same' ? (phone ? 'same' : null) : (patient.whatsapp ?? null)
        if (Object.keys(errors).length) return validationError(errors)
        Object.assign(patient, rest, { phone, whatsapp: whatsapp === phone ? 'same' : whatsapp })
        return reply(200, detailDto(patient), tenant)
      }
      if (method === 'DELETE') {
        if (!roles.includes('tenant_admin') && !roles.includes('receptionist')) return forbidden()
        const open = this.appointments.some((a) => a.patientId === patient.id && ['booked', 'checked_in', 'in_consultation'].includes(a.status)) || this.queue.some((q) => q.patientId === patient.id && ['waiting', 'in_consultation'].includes(q.status))
        if (open) return problem(409, 'invalid_state', { detail: 'The patient has open appointments or queue entries.' })
        patient.deletedAt = new Date().toISOString()
        return reply(204, undefined, tenant)
      }
    }
    if (method === 'POST' && restoreMatch) {
      if (!roles.includes('tenant_admin')) return forbidden()
      const patient = this.patients.find((p) => p.tenantId === tenant && p.id === restoreMatch[1] && p.deletedAt)
      if (!patient) return notFound()
      patient.deletedAt = null
      return reply(204, undefined, tenant)
    }

    // --- Sprint 2: practitioners, schedules, slots, appointments, queue ---------------------------
    const strip = <T extends { tenantId: string }>({ tenantId: _t, ...rest }: T) => rest
    // API v2: embedded patient summary on appointment/queue rows (omitted when legacyApi).
    const withPatient = <T extends { tenantId: string; patientId: string }>(row: T) => {
      if (this.legacyApi) return strip(row)
      const p = this.patients.find((x) => x.id === row.patientId)
      // null when soft-deleted (or not readable), like the API's RLS-scoped LEFT JOIN
      return { ...strip(row), patient: p && !p.deletedAt ? { id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName } : null }
    }
    const isAdmin = roles.includes('tenant_admin')
    const livePractitioners = this.practitioners.filter((p) => p.tenantId === tenant && !p.isDeleted)
    const schedules = this.schedules.filter((x) => x.tenantId === tenant && !x.isDeleted && livePractitioners.some((p) => p.id === x.practitionerId))
    const practitioners = livePractitioners
    const scheduleOverlaps = (c: MockSchedule) =>
      this.schedules.some((o) => o.id !== c.id && !o.isDeleted && o.isActive && o.practitionerId === c.practitionerId && o.weekday === c.weekday && o.startTime < c.endTime && o.endTime > c.startTime && o.validFrom <= (c.validTo ?? '9999-12-31') && c.validFrom <= (o.validTo ?? '9999-12-31'))
    if (method === 'GET' && path === '/api/v1/practitioners') {
      const branchId = url.searchParams.get('branchId')
      const includeDeleted = url.searchParams.get('includeDeleted') === 'true'
      if (includeDeleted && !isAdmin) return forbidden()
      if (branchId && this.legacyApi) return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['Unknown parameter.'] } }, tenant)
      if (branchId && !tenants[tenant]!.branches.some((b) => b.id === branchId)) return notFound() // foreign branch (v2)
      // v2: practitioners with an active schedule at the branch (validTo null or ≥ branch today)
      const atBranch = branchId ? new Set(schedules.filter((s) => s.branchId === branchId && s.isActive && (!s.validTo || s.validTo >= todayIn(this.branchZone(branchId)))).map((s) => s.practitionerId)) : null
      const pool = includeDeleted ? this.practitioners.filter((p) => p.tenantId === tenant) : practitioners
      return reply(200, pool.filter((p) => (url.searchParams.get('activeOnly') !== 'true' || p.isActive) && (!atBranch || atBranch.has(p.id))).map((p) => ({ ...strip(p), isDeleted: !!p.isDeleted })), tenant)
    }
    if (method === 'GET' && path === '/api/v1/schedules') {
      const branchId = url.searchParams.get('branchId')
      const practitionerId = url.searchParams.get('practitionerId')
      const includeDeleted = url.searchParams.get('includeDeleted') === 'true'
      if (includeDeleted && !isAdmin) return forbidden()
      const pool = includeDeleted ? this.schedules.filter((x) => x.tenantId === tenant) : schedules
      return reply(200, pool.filter((x) => (!branchId || x.branchId === branchId) && (!practitionerId || x.practitionerId === practitionerId)).map((x) => ({ ...strip(x), isDeleted: !!x.isDeleted })), tenant)
    }
    const practitionerMatch = /^\/api\/v1\/practitioners\/([^/]+)(\/restore)?$/.exec(path)
    if (method === 'POST' && path === '/api/v1/practitioners') {
      if (!isAdmin) return forbidden()
      if (!String(body.displayName ?? '').trim()) return reply(400, { title: 'Validation', status: 400, errors: { displayName: ['Display name is required.'] } }, tenant)
      const created: MockPractitioner = { id: crypto.randomUUID(), tenantId: tenant, userId: (body.userId as string) ?? null, displayName: String(body.displayName).trim(), specialty: (body.specialty as string) ?? null, isActive: true }
      this.practitioners.push(created)
      return reply(201, { ...strip(created), isDeleted: false }, tenant)
    }
    if (practitionerMatch) {
      const p = this.practitioners.find((x) => x.tenantId === tenant && x.id === practitionerMatch[1])
      if (!isAdmin) return forbidden()
      if (!p) return notFound()
      if (method === 'POST' && practitionerMatch[2]) {
        if (!p.isDeleted) return notFound()
        p.isDeleted = false
        return reply(204, undefined, tenant)
      }
      if (p.isDeleted) return notFound()
      if (method === 'PATCH') {
        if (body.displayName !== undefined) p.displayName = String(body.displayName)
        if (body.specialty !== undefined) p.specialty = (body.specialty as string | null) ?? null
        if (body.isActive !== undefined) p.isActive = !!body.isActive
        if (body.userId) p.userId = String(body.userId)
        if (body.unlinkUser) p.userId = null
        return reply(200, { ...strip(p), isDeleted: false }, tenant)
      }
      if (method === 'DELETE') {
        if (this.appointments.some((x) => x.practitionerId === p.id && ['booked', 'checked_in', 'in_consultation'].includes(x.status))) return problem(409, 'invalid_state', { detail: 'The practitioner has open appointments.' })
        // like appointment.soft_delete_practitioner: deleted and inactive (restore keeps it inactive)
        p.isDeleted = true
        p.isActive = false
        return reply(204, undefined, tenant)
      }
    }
    const scheduleMatch = /^\/api\/v1\/schedules\/([^/]+)(\/restore)?$/.exec(path)
    if (method === 'POST' && path === '/api/v1/schedules') {
      if (!isAdmin) return forbidden()
      if (!practitioners.some((p) => p.id === body.practitionerId) || !tenants[tenant]!.branches.some((b) => b.id === body.branchId)) return notFound()
      const created: MockSchedule = { id: crypto.randomUUID(), tenantId: tenant, practitionerId: String(body.practitionerId), branchId: String(body.branchId), weekday: Number(body.weekday), startTime: String(body.startTime), endTime: String(body.endTime), slotMinutes: Number(body.slotMinutes ?? 15), validFrom: String(body.validFrom), validTo: (body.validTo as string | null) ?? null, isActive: true }
      if (scheduleOverlaps(created)) return problem(409, 'schedule_overlap', { detail: 'The practitioner already has an overlapping active schedule on that weekday.' })
      this.schedules.push(created)
      return reply(201, { ...strip(created), isDeleted: false }, tenant)
    }
    if (scheduleMatch) {
      const x = this.schedules.find((y) => y.tenantId === tenant && y.id === scheduleMatch[1])
      if (!isAdmin) return forbidden()
      if (!x) return notFound()
      if (method === 'POST' && scheduleMatch[2]) {
        if (!x.isDeleted) return notFound()
        if (x.isActive && scheduleOverlaps(x)) return problem(409, 'schedule_overlap')
        x.isDeleted = false
        return reply(204, undefined, tenant)
      }
      if (x.isDeleted) return notFound()
      if (method === 'PATCH') {
        const next: MockSchedule = { ...x }
        for (const k of ['weekday', 'slotMinutes'] as const) if (body[k] !== undefined) next[k] = Number(body[k])
        for (const k of ['startTime', 'endTime', 'validFrom', 'validTo'] as const) if (body[k] !== undefined) next[k] = String(body[k])
        if (body.clearValidTo) next.validTo = null
        if (body.isActive !== undefined) next.isActive = !!body.isActive
        if (next.isActive && scheduleOverlaps(next)) return problem(409, 'schedule_overlap')
        Object.assign(x, next)
        return reply(200, { ...strip(x), isDeleted: false }, tenant)
      }
      if (method === 'DELETE') {
        x.isDeleted = true
        return reply(204, undefined, tenant)
      }
    }
    if (method === 'GET' && path === '/api/v1/slots') {
      if (!has(REG_READ)) return forbidden()
      const branchId = url.searchParams.get('branchId')!
      const practitionerId = url.searchParams.get('practitionerId')
      const from = url.searchParams.get('from')!
      const to = url.searchParams.get('to')!
      const slots: unknown[] = []
      for (let d = from; d <= to; d = addDays(d, 1)) {
        for (const s of schedules.filter((x) => x.tenantId === tenant && x.branchId === branchId && x.isActive && x.validFrom <= d && (!x.validTo || x.validTo >= d) && x.weekday === isoWeekday(d) && (!practitionerId || x.practitionerId === practitionerId))) {
          for (let start = branchInstant(d, s.startTime); start < branchInstant(d, s.endTime); ) {
            const end = new Date(Date.parse(start) + s.slotMinutes * 60_000).toISOString()
            const taken = this.appointments.some((a) => a.practitionerId === s.practitionerId && BLOCKING.includes(a.status) && a.startsAt < end && a.endsAt > start)
            if (!taken && Date.parse(start) > Date.now()) slots.push({ practitionerId: s.practitionerId, branchId, startsAt: start, endsAt: end })
            start = end
          }
        }
      }
      return reply(200, slots, tenant)
    }
    const apptAction = /^\/api\/v1\/appointments\/([^/]+)\/(cancel|check-in|reschedule|no-show)$/.exec(path)
    if (method === 'GET' && path === '/api/v1/appointments') {
      if (!has(REG_READ)) return forbidden()
      const q = url.searchParams
      const items = this.appointments
        .filter((a) => a.tenantId === tenant && (!q.get('branchId') || a.branchId === q.get('branchId')) && (!q.get('patientId') || a.patientId === q.get('patientId')) && (!q.get('practitionerId') || a.practitionerId === q.get('practitionerId')) && (!q.get('from') || a.endsAt > new Date(q.get('from')!).toISOString()) && (!q.get('to') || a.startsAt < new Date(q.get('to')!).toISOString()) && (!q.get('status') || a.status === q.get('status')))
        .sort((a, b) => a.startsAt.localeCompare(b.startsAt))
        .map(withPatient)
      const size = Number(q.get('pageSize') ?? 25)
      return reply(200, { items: items.slice(0, size), page: 1, pageSize: size, totalCount: items.length }, tenant)
    }
    if (method === 'POST' && path === '/api/v1/appointments') {
      const branchId = String(body.branchId)
      // A clinician with follow-up permission books a follow-up of any earlier visit at a branch they can access.
      const followUp = rolesAt(branchId).includes('doctor') && !!body.parentAppointmentId
      if (!canAccessBranch(branchId) || (!has(REG_WRITE, rolesAt(branchId)) && !followUp)) return forbidden()
      // Contract v4: foreign/unknown/soft-deleted patient or practitioner → 404 (was 400 invalid_reference).
      if (!livePatients.some((p) => p.id === body.patientId) || !practitioners.some((p) => p.tenantId === tenant && p.id === body.practitionerId)) return notFound()
      const startsAt = new Date(String(body.startsAt)).toISOString()
      const endsAt = new Date(String(body.endsAt)).toISOString()
      if (this.appointments.some((a) => a.practitionerId === body.practitionerId && BLOCKING.includes(a.status) && a.startsAt < endsAt && a.endsAt > startsAt)) {
        return problem(409, 'appointment_overlap', { detail: 'The practitioner already has an appointment at that time.' })
      }
      const created: MockAppointment = { id: uuid('a2000000'), tenantId: tenant, branchId, practitionerId: String(body.practitionerId), patientId: String(body.patientId), startsAt, endsAt, status: 'booked', reason: (body.reason as string) ?? null, cancelReason: null }
      this.appointments.push(created)
      this.lastBooked.set(created.patientId, Date.now())
      return reply(201, withPatient(created), tenant)
    }
    if (method === 'POST' && apptAction) {
      const appt = this.appointments.find((a) => a.tenantId === tenant && a.id === apptAction[1])
      if (!appt) return notFound()
      if (apptAction[2] === 'reschedule') {
        if (!has(REG_WRITE, rolesAt(appt.branchId))) return forbidden()
        if (appt.status !== 'booked') return problem(409, 'invalid_transition')
        const practitionerId = (body.practitionerId as string) || appt.practitionerId
        const startsAt = new Date(String(body.startsAt)).toISOString()
        const endsAt = new Date(String(body.endsAt)).toISOString()
        if (this.appointments.some((a) => a.id !== appt.id && a.practitionerId === practitionerId && BLOCKING.includes(a.status) && a.startsAt < endsAt && a.endsAt > startsAt)) return problem(409, 'appointment_overlap')
        Object.assign(appt, { practitionerId, startsAt, endsAt })
        return reply(200, withPatient(appt), tenant)
      }
      if (apptAction[2] === 'no-show') {
        if (!has(NO_SHOW, rolesAt(appt.branchId))) return forbidden()
        if (appt.status !== 'booked' || appt.startsAt > new Date().toISOString()) return problem(409, 'invalid_transition')
        appt.status = 'no_show'
        return reply(200, withPatient(appt), tenant)
      }
      if (apptAction[2] === 'cancel') {
        if (!has(REG_WRITE, rolesAt(appt.branchId))) return forbidden()
        if (!['booked', 'checked_in'].includes(appt.status)) return problem(409, 'invalid_transition')
        appt.status = 'cancelled'
        appt.cancelReason = (body.reason as string) ?? null
        return reply(200, withPatient(appt), tenant)
      }
      if (!has(FRONT_DESK, rolesAt(appt.branchId))) return forbidden()
      if (appt.status !== 'booked') return problem(409, 'invalid_transition')
      const today = branchToday()
      if (branchToday(new Date(appt.startsAt)) !== today) return problem(409, 'invalid_state')
      if (this.queue.some((q) => q.branchId === appt.branchId && q.queueDate === today && q.patientId === appt.patientId && ['waiting', 'in_consultation'].includes(q.status))) return problem(409, 'already_checked_in')
      const entry = this.issueToken(appt.branchId, appt.patientId, appt.practitionerId)
      entry.appointmentId = appt.id
      appt.status = 'checked_in'
      return reply(201, { queueEntryId: entry.id, tokenNo: entry.tokenNo, queueDate: entry.queueDate, entry: withPatient(entry) }, tenant)
    }
    if (method === 'GET' && path === '/api/v1/queue') {
      const branchId = url.searchParams.get('branchId')!
      if (!has(QUEUE_READ) || !canAccessBranch(branchId)) return forbidden()
      const date = url.searchParams.get('date') ?? branchToday()
      return reply(200, this.queue.filter((q) => q.tenantId === tenant && q.branchId === branchId && q.queueDate === date).sort((a, b) => a.tokenNo - b.tokenNo).map(withPatient), tenant)
    }
    if (method === 'POST' && path === '/api/v1/queue/walk-in') {
      const branchId = String(body.branchId)
      if (!canAccessBranch(branchId) || !has(FRONT_DESK, rolesAt(branchId))) return forbidden()
      if (!livePatients.some((p) => p.id === body.patientId)) return notFound()
      if (this.queue.some((q) => q.branchId === branchId && q.queueDate === branchToday() && q.patientId === body.patientId && ['waiting', 'in_consultation'].includes(q.status))) return problem(409, 'already_checked_in')
      const entry = this.issueToken(branchId, String(body.patientId), (body.practitionerId as string) ?? null)
      return reply(201, { queueEntryId: entry.id, tokenNo: entry.tokenNo, queueDate: entry.queueDate, entry: withPatient(entry) }, tenant)
    }
    const queueMatch = /^\/api\/v1\/queue\/([^/]+)$/.exec(path)
    if (method === 'PATCH' && queueMatch) {
      const entry = this.queue.find((q) => q.tenantId === tenant && q.id === queueMatch[1])
      if (!entry || !canAccessBranch(entry.branchId)) return notFound()
      const next = String(body.status)
      const branchRoles = rolesAt(entry.branchId)
      const allowed = has(FRONT_DESK, branchRoles) || (branchRoles.includes('doctor') && ['in_consultation', 'done'].includes(next))
      if (!allowed) return forbidden()
      if (!QUEUE_TRANSITIONS[entry.status]?.includes(next)) return problem(409, 'invalid_transition', { detail: `invalid_transition:${entry.status}->${next}` })
      entry.status = next
      const now = new Date().toISOString()
      if (next === 'in_consultation') entry.calledAt = now
      if (next === 'done') entry.completedAt = now
      if (next === 'cancelled') entry.cancelledAt = now
      const appt = this.appointments.find((a) => a.id === entry.appointmentId)
      if (appt) appt.status = next === 'done' ? 'completed' : next
      return reply(200, withPatient(entry), tenant)
    }

    const branchDto = (b: { id: string; name: string; code: string }) => ({
      ...b,
      name: this.branchNames.get(b.id) ?? b.name,
      timezone: this.branchZone(b.id),
      timezoneOverride: this.branchTimeZones.get(b.id) ?? null,
      isActive: this.branchState.get(b.id)?.isActive ?? true,
      isDeleted: this.branchState.get(b.id)?.isDeleted ?? false,
    })
    // Future bookings whose wall-clock time would move with a zone change (identity.change_time_zone_v1).
    const futureBookings = (branchIds: string[]) =>
      this.appointments.filter((a) => branchIds.includes(a.branchId) && a.status === 'booked' && a.startsAt > new Date().toISOString()).length
    const tenantBranches = () => [...tenants[tenant]!.branches, ...this.createdBranches]
    if (method === 'POST' && path === '/api/v1/branches') {
      if (!isAdmin) return forbidden()
      const code = String(body.code ?? '').trim()
      const name = String(body.name ?? '').trim()
      if (!/^[a-z0-9][a-z0-9-]{1,39}$/.test(code)) return reply(400, { title: 'Validation', status: 400, errors: { code: ['2-40 lowercase letters, digits or hyphens'] } }, tenant)
      if (!name) return reply(400, { title: 'Validation', status: 400, errors: { name: ['Name is required'] } }, tenant)
      if (tenantBranches().some((b) => b.code === code && !this.branchState.get(b.id)?.isDeleted)) return problem(409, 'conflict')
      const created = { id: crypto.randomUUID(), name, code }
      this.createdBranches.push(created)
      if (typeof body.timezone === 'string' && body.timezone) this.branchTimeZones.set(created.id, body.timezone)
      return reply(201, branchDto(created), tenant)
    }
    if (method === 'GET' && path === '/api/v1/branches') {
      const withDeleted = isAdmin && url.searchParams.get('includeDeleted') === 'true'
      return reply(200, tenantBranches().map(branchDto).filter((b) => (withDeleted || !b.isDeleted) && (isAdmin || b.isActive)), tenant)
    }
    const branchRestore = /^\/api\/v1\/branches\/([^/]+)\/restore$/.exec(path)
    if ((method === 'DELETE' && /^\/api\/v1\/branches\/[^/]+$/.test(path)) || (method === 'POST' && branchRestore)) {
      if (!isAdmin) return forbidden()
      const id = branchRestore ? branchRestore[1]! : path.split('/').pop()!
      const b = tenants[tenant]!.branches.find((x) => x.id === id)
      const st = this.branchState.get(id) ?? { isActive: true, isDeleted: false }
      if (!b || st.isDeleted === (method === 'DELETE')) return notFound()
      if (method === 'DELETE') {
        if (tenants[tenant]!.branches.filter((x) => !this.branchState.get(x.id)?.isDeleted).length <= 1) return problem(409, 'invalid_state', { detail: 'a hospital needs at least one branch' })
        if (this.appointments.some((a) => a.branchId === id && ['booked', 'checked_in', 'in_consultation'].includes(a.status)) || this.queue.some((q) => q.branchId === id && ['waiting', 'in_consultation'].includes(q.status)))
          return problem(409, 'invalid_state', { detail: 'branch has open appointments or queue entries' })
        this.branchState.set(id, { isActive: false, isDeleted: true })
      } else this.branchState.set(id, { isActive: false, isDeleted: false }) // restored inactive, like the SQL
      return reply(204, undefined, tenant)
    }
    const branchMatch = /^\/api\/v1\/branches\/([^/]+)$/.exec(path)
    if (method === 'PATCH' && branchMatch) {
      if (!isAdmin) return forbidden()
      const b = tenants[tenant]!.branches.find((x) => x.id === branchMatch[1])
      if (!b) return notFound()
      const zoneChange = body.inheritTimezone ? this.branchTimeZones.has(b.id) : typeof body.timezone === 'string' && body.timezone !== this.branchZone(b.id)
      if (zoneChange && !body.confirmFutureBookings && futureBookings([b.id]) > 0) return problem(409, 'time_zone_has_future_bookings', { futureBookings: futureBookings([b.id]) })
      if (body.inheritTimezone) this.branchTimeZones.delete(b.id)
      else if (typeof body.timezone === 'string') this.branchTimeZones.set(b.id, body.timezone)
      if (typeof body.name === 'string') this.branchNames.set(b.id, body.name)
      if (typeof body.isActive === 'boolean') this.branchState.set(b.id, { isActive: body.isActive, isDeleted: false })
      return reply(200, branchDto(b), tenant)
    }
    const tenantDto = () => ({ id: tenant, code: tenant === ids.alpha ? 'alpha' : 'beta', name: this.tenantNames.get(tenant) ?? tenants[tenant]!.name, activeBranchId: null, roles, timeZone: this.tenantZone(tenant), defaultCountryCode: tenant === ids.alpha ? '+91' : '+971', setupStep: 'done', setupCompletedOn: '2026-01-01T00:00:00.000Z' })
    if (method === 'GET' && path === '/api/v1/tenants/current') return reply(200, tenantDto(), tenant)
    if (method === 'PATCH' && path === '/api/v1/tenants/current') {
      if (!isAdmin) return forbidden()
      if (typeof body.timeZone === 'string' && body.timeZone !== this.tenantZone(tenant)) {
        const following = tenants[tenant]!.branches.filter((b) => !this.branchTimeZones.has(b.id)).map((b) => b.id)
        const n = futureBookings(following)
        if (n > 0 && !body.confirmFutureBookings) return problem(409, 'time_zone_has_future_bookings', { futureBookings: n })
        this.tenantTimeZones.set(tenant, body.timeZone)
      }
      if (typeof body.name === 'string') this.tenantNames.set(tenant, body.name)
      return reply(200, tenantDto(), tenant)
    }
    if (method === 'GET' && path === '/api/v1/patients/stats') {
      if (!has(REG_READ)) return forbidden()
      const branchId = url.searchParams.get('branchId')
      if (branchId && !tenants[tenant]!.branches.some((b) => b.id === branchId)) return notFound()
      const rows = livePatients.filter((p) => !branchId || p.registeredBranchId === branchId)
      const today = (p: MockPatient) => !!p.createdOn && todayIn(this.branchZone(p.registeredBranchId), new Date(p.createdOn!)) === todayIn(this.branchZone(p.registeredBranchId))
      return reply(200, { total: rows.length, registeredToday: rows.filter(today).length }, tenant)
    }
    if (method === 'GET' && path === '/api/v1/members') {
      const rows = [...this.users.values()].flatMap((u) =>
        u.memberships
          .filter((m) => m.tenantId === tenant && m.status !== 'invited') // pending invites are hidden from admins
          .map((m) => ({ id: m.id, userId: u.id, email: u.email, displayName: null, role: m.role, branchId: m.branchId, branchName: null, status: m.status })),
      )
      return reply(200, rows, tenant)
    }
    if (method === 'POST' && path === '/api/v1/members') {
      if (!roles.includes('tenant_admin')) return reply(403, { title: 'Forbidden', status: 403 }, tenant)
      if (body.role === 'tenant_admin' && body.branchId) {
        return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['tenant_admin is tenant-wide: omit branchId.'] } }, tenant)
      }
      this.invite(String(body.email).toLowerCase(), tenant, String(body.role), (body.branchId as string | null) ?? null)
      return reply(202, { message: ADD_MEMBER_GENERIC_MESSAGE }, tenant)
    }
    const memberMatch = /^\/api\/v1\/members\/([^/]+)$/.exec(path)
    if (memberMatch && memberMatch[1] !== 'invite-links' && (method === 'PATCH' || method === 'DELETE')) {
      if (!isAdmin) return forbidden()
      const owner = [...this.users.values()].find((u) => u.memberships.some((m) => m.id === memberMatch[1] && m.tenantId === tenant))
      const m = owner?.memberships.find((x) => x.id === memberMatch[1])
      if (!owner || !m) return notFound()
      if (owner.id === user.id) return problem(409, 'conflict', { detail: 'You cannot change your own membership.' })
      if (method === 'DELETE') {
        owner.memberships.splice(owner.memberships.indexOf(m), 1)
        return reply(204, undefined, tenant)
      }
      if (typeof body.role === 'string') m.role = body.role
      if (typeof body.status === 'string') m.status = body.status as Membership['status']
      if (typeof body.branchId === 'string') {
        if (m.role === 'tenant_admin') return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['tenant_admin is tenant-wide: omit branchId.'] } }, tenant)
        if (!tenants[tenant]!.branches.some((b) => b.id === body.branchId)) return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['Unknown branch.'] } }, tenant)
        m.branchId = body.branchId
      }
      if (body.allBranches === true) m.branchId = null
      return reply(200, { id: m.id, userId: owner.id, email: owner.email, displayName: null, role: m.role, branchId: m.branchId, branchName: null, status: m.status }, tenant)
    }
    if (path === '/api/v1/members/invite-links' || path.startsWith('/api/v1/members/invite-links/')) {
      if (!isAdmin) return forbidden()
      if (method === 'GET') {
        const now = new Date().toISOString()
        return reply(
          200,
          this.inviteLinks
            .filter((l) => l.tenantId === tenant)
            .map(({ token: _t, tenantId: _x, tenantName: _n, ...l }) => ({ ...l, status: l.status === 'pending' && l.expiresOn <= now ? 'expired' : l.status })),
          tenant,
        )
      }
      if (method === 'POST') {
        if (body.role === 'tenant_admin' && body.branchId) return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['tenant_admin is tenant-wide: omit branchId.'] } }, tenant)
        const issued = this.issueInviteLink(tenant, tenants[tenant]!.name, String(body.email).toLowerCase(), String(body.role), (body.branchId as string | null) ?? null, 7)
        return reply(201, issued, tenant)
      }
      if (method === 'DELETE') {
        const link = this.inviteLinks.find((l) => l.tenantId === tenant && l.id === path.split('/').pop() && l.status === 'pending')
        if (!link) return notFound()
        link.status = 'revoked'
        return reply(204, undefined, tenant)
      }
    }
    return reply(404, { title: 'Not found', status: 404 }, tenant)
  }

  /** identity.issue_invite_link: supersedes pending links for the same tenant/email/branch; returns the token once. */
  issueInviteLink(tenantId: string, tenantName: string, email: string, role: string, branchId: string | null, days: number) {
    for (const l of this.inviteLinks) if (l.tenantId === tenantId && l.email === email && l.branchId === branchId && l.status === 'pending') l.status = 'revoked'
    const n = ++seq
    const token = Array.from({ length: 64 }, (_, i) => '0123456789abcdef'[(n * 7 + i * 13 + email.length * (i + 1)) % 16]).join('')
    const link: MockInviteLink = { id: uuid('1c000000'), tenantId, tenantName, email, role, branchId, token, status: 'pending', expiresOn: new Date(Date.now() + days * 86_400_000).toISOString(), createdOn: new Date().toISOString(), claimedOn: null }
    this.inviteLinks.push(link)
    return { id: link.id, token, path: `/invite/${token}`, expiresOn: link.expiresOn }
  }

  private platformTenantList() {
    const seeded = Object.entries(tenants).map(([id, t]) => ({
      id,
      code: id === ids.alpha ? 'alpha' : 'beta',
      name: this.tenantNames.get(id) ?? t.name,
      timeZone: this.tenantZone(id),
      createdOn: id === ids.alpha ? '2026-09-01T04:30:00.000Z' : '2026-09-15T04:30:00.000Z',
      branchCount: t.branches.filter((b) => !this.branchState.get(b.id)?.isDeleted).length,
      userCount: [...this.users.values()].filter((u) => u.memberships.some((m) => m.tenantId === id && m.status === 'active')).length,
    }))
    return [...seeded, ...this.platformTenants].map((t) => {
      const st = this.tenantStatus.get(t.id)
      return {
        ...t,
        status: st?.status ?? 'active',
        pendingInvites: this.inviteLinks.filter((l) => l.tenantId === t.id && l.status === 'pending').length,
        statusReason: st?.history.at(-1)?.reason ?? null,
      }
    })
  }

  private handlePlatform(method: string, path: string, url: URL, body: Record<string, unknown>, user: MockUser, reply: (status: number, body?: unknown) => Promise<void>) {
    const p = (status: number, code: string, detail?: string) => reply(status, { title: code, status, code, ...(detail ? { detail } : {}) })
    const invalid = (errors: Record<string, string[]>) => reply(400, { title: 'Validation', status: 400, errors })
    const zoneOk = (z: unknown) => typeof z === 'string' && (z === 'UTC' || /^[A-Z][A-Za-z_]+\/[A-Za-z_/-]+$/.test(z)) && !z.startsWith('Mars/')
    const codeOk = (c: unknown) => /^[a-z0-9][a-z0-9-]{1,39}$/.test(String(c ?? ''))
    const createTenant = (code: string, name: string, timeZone: string) => {
      if (this.platformTenantList().some((t) => t.code === code)) return null
      const t: MockPlatformTenant = { id: uuid('7e000000'), code, name, timeZone, createdOn: new Date().toISOString(), branchCount: 1, userCount: 0 }
      this.platformTenants.push(t)
      return t
    }
    if (method === 'GET' && path === '/api/v1/platform/tenants') {
      const search = (url.searchParams.get('search') ?? '').toLowerCase()
      const status = url.searchParams.get('status')
      return reply(200, this.platformTenantList().filter((t) => (!search || `${t.name} ${t.code}`.toLowerCase().includes(search)) && (!status || t.status === status)).sort((a, b) => a.name.localeCompare(b.name)))
    }
    if (method === 'POST' && path === '/api/v1/platform/tenants') {
      const errors: Record<string, string[]> = {}
      if (!codeOk(body.code)) errors.code = ['2-40 lowercase letters, digits or hyphens']
      if (!zoneOk(body.timeZone)) errors.timeZone = ['Unknown IANA time zone.']
      if (Object.keys(errors).length) return invalid(errors)
      const t = createTenant(String(body.code), String(body.name), String(body.timeZone))
      if (!t) return p(409, 'conflict', 'A live record with the same key already exists.')
      return reply(201, { tenantId: t.id, invite: this.issueInviteLink(t.id, t.name, String(body.adminEmail).toLowerCase(), 'tenant_admin', null, 14) })
    }
    const tm = /^\/api\/v1\/platform\/tenants\/([^/]+)(?:\/(suspend|reactivate|admin-invite))?$/.exec(path)
    if (tm) {
      const t = this.platformTenantList().find((x) => x.id === tm[1])
      if (!t) return p(404, 'not_found')
      if (method === 'GET' && !tm[2]) return reply(200, { tenant: t, history: [...(this.tenantStatus.get(t.id)?.history ?? [])].reverse() })
      if (method === 'POST' && tm[2] === 'admin-invite') return reply(201, this.issueInviteLink(t.id, t.name, String(body.email).toLowerCase(), 'tenant_admin', null, 14))
      if (method === 'POST' && tm[2]) {
        const to = tm[2] === 'suspend' ? 'suspended' : 'active'
        if (String(body.reason ?? '').trim().length < 3) return invalid({ reason: ['Give a reason (3-500 characters).'] })
        if (t.status === to) return p(409, 'invalid_state', `tenant is already ${to}`)
        const st = this.tenantStatus.get(t.id) ?? { status: 'active' as const, history: [] }
        st.history.push({ fromStatus: t.status, toStatus: to, reason: String(body.reason).trim(), changedOn: new Date().toISOString(), changedBy: user.email })
        st.status = to
        this.tenantStatus.set(t.id, st)
        return reply(200, this.platformTenantList().find((x) => x.id === t.id))
      }
    }
    if (method === 'GET' && path === '/api/v1/platform/hospital-requests') {
      const status = url.searchParams.get('status')
      return reply(200, this.signups.filter((x) => !status || x.status === status).sort((a, b) => b.createdOn.localeCompare(a.createdOn)))
    }
    const rm = /^\/api\/v1\/platform\/hospital-requests\/([^/]+)\/(approve|reject)$/.exec(path)
    if (method === 'POST' && rm) {
      const r = this.signups.find((x) => x.id === rm[1])
      if (!r) return p(404, 'not_found')
      if (r.status !== 'pending') return p(409, 'invalid_state', 'request already decided')
      if (rm[2] === 'approve' && r.possibleDuplicate && body.acknowledgeDuplicate !== true) {
        return p(409, 'possible_duplicate', 'This request may duplicate an existing hospital. Confirm to approve it.')
      }
      if (rm[2] === 'reject') {
        if (String(body.reason ?? '').trim().length < 3) return invalid({ reason: ['Give a reason (3-500 characters).'] })
        Object.assign(r, { status: 'rejected', decisionReason: String(body.reason).trim(), decidedOn: new Date().toISOString() })
        return reply(204)
      }
      if (!codeOk(body.tenantCode)) return invalid({ tenantCode: ['2-40 lowercase letters, digits or hyphens'] })
      const code = String(body.tenantCode)
      const t = createTenant(code, r.hospitalName, r.timeZone)
      if (!t) return p(409, 'conflict', 'A live record with the same key already exists.')
      Object.assign(r, { status: 'approved', decidedOn: new Date().toISOString(), tenantId: t.id, tenantCode: code })
      return reply(200, { tenantId: t.id, invite: this.issueInviteLink(t.id, t.name, r.contactEmail, 'tenant_admin', null, 14) })
    }
    return p(404, 'not_found')
  }
}


export async function signIn(page: Page, email: string) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('heading', { name: 'Dashboard' }).waitFor()
}

/** Second tab sharing the first tab's sessionStorage copy (window.open), like "open in new tab". */
export async function openSecondTab(page: Page, path = '/') {
  const [popup] = await Promise.all([page.context().waitForEvent('page'), page.evaluate((p) => window.open(p, '_blank'), path)])
  await popup.waitForLoadState()
  return popup
}
