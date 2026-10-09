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
 * API v2 (CTO, 2026-10-09): appointment/queue/check-in/walk-in responses embed
 * `patient: { id, mrn, firstName, lastName }`. `backend.legacyApi = true` simulates an older API:
 * no summary, and `?branchId=` on /practitioners → 400. POST/PATCH /patients reject a DOB after
 * today in the registered branch's zone (`backend.branchTimeZones` overrides a branch's zone).
 * Writes check the role held *at the row's branch*; branch-bound members only see their branches.
 * The resolved tenant is per USER (server-side), like identity.user_profiles, so a "switch on
 * another device" is simulated with `backend.setActiveTenant()`.
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
  phone: string | null
  email: string | null
  deletedAt: string | null
}

const seedPatients = (): MockPatient[] => [
  { id: patientIds.asha, tenantId: ids.alpha, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female', registeredBranchId: ids.alphaMain, phone: '+91 98450 00001', email: null, deletedAt: null },
  { id: patientIds.ravi, tenantId: ids.alpha, mrn: 'ALP-0002', firstName: 'Ravi', lastName: 'Synthetic-Alpha', dateOfBirth: '1985-05-05', sex: 'male', registeredBranchId: ids.alphaEast, phone: '+91 98450 00002', email: null, deletedAt: null },
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

const practitioners = [
  { id: practitionerIds.rao, tenantId: ids.alpha, userId: null, displayName: 'Dr. Rao (synthetic)', specialty: 'General medicine', isActive: true },
  { id: practitionerIds.iyer, tenantId: ids.alpha, userId: null, displayName: 'Dr. Iyer (synthetic)', specialty: 'Paediatrics', isActive: true },
  { id: practitionerIds.betaDoc, tenantId: ids.beta, userId: null, displayName: 'Dr. Beta (synthetic)', specialty: null, isActive: true },
]

/** Dr. Rao: every day 09:00–13:00 at Alpha Main (15 min). Dr. Iyer: every day 14:00–16:00 at Alpha East (20 min). */
const schedules = [
  ...[1, 2, 3, 4, 5, 6, 7].map((weekday) => ({ id: `5c000000-0000-4000-8000-00000000000${weekday}`, tenantId: ids.alpha, practitionerId: practitionerIds.rao, branchId: ids.alphaMain, weekday, startTime: '09:00', endTime: '13:00', slotMinutes: 15, validFrom: '2026-01-01', validTo: null, isActive: true })),
  ...[1, 2, 3, 4, 5, 6, 7].map((weekday) => ({ id: `5c000000-0000-4000-8000-00000000010${weekday}`, tenantId: ids.alpha, practitionerId: practitionerIds.iyer, branchId: ids.alphaEast, weekday, startTime: '14:00', endTime: '16:00', slotMinutes: 20, validFrom: '2026-01-01', validTo: null, isActive: true })),
]

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
  createdAt: string
}

interface MockUser {
  id: string
  email: string
  memberships: Membership[]
  activeTenantId: string | null
}

export interface RecordedCall {
  method: string
  url: string
  path: string
  body: unknown
  headers: Record<string, string>
}

let seq = 0
const uuid = (prefix: string) => `${prefix}${String(++seq).padStart(12, '0')}`.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12}).*$/, '$1-$2-$3-$4-$5')

const b64url = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url')

export class MockBackend {
  readonly calls: RecordedCall[] = []
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
    // Today's booked appointment for Asha with Dr. Rao (check-in flow).
    const today = branchToday()
    this.appointments.push({ id: 'a0000000-0000-4000-8000-000000000001', tenantId: ids.alpha, branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.asha, startsAt: branchInstant(today, '09:30'), endsAt: branchInstant(today, '09:45'), status: 'booked', reason: null, cancelReason: null })
  }

  /** true = pre-v2 API: no embedded patient summary, `/practitioners?branchId=` → 400. */
  legacyApi = false
  /** Per-branch IANA zone overrides (default BRANCH_TZ). */
  readonly branchTimeZones = new Map<string, string>()
  branchZone(branchId: string) {
    return this.branchTimeZones.get(branchId) ?? BRANCH_TZ
  }

  readonly patients: MockPatient[] = seedPatients()
  readonly appointments: MockAppointment[] = []
  readonly queue: MockQueueEntry[] = []
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
    return { id: uuid('cc000000'), tenantId, branchId, role, status, createdAt: new Date(Date.now() + seq).toISOString() }
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
    const active = user.memberships.filter((m) => m.status === 'active').sort((a, b) => a.createdAt.localeCompare(b.createdAt))
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

  private async handleApi(route: Route) {
    const request = route.request()
    this.record(request)
    const url = new URL(request.url())
    const method = request.method()
    const path = url.pathname
    const reply = (status: number, body?: unknown, tenant?: string | null) =>
      route.fulfill({
        status,
        headers: { 'content-type': 'application/json', ...(tenant ? { 'X-Hms-Tenant': tenant } : {}) },
        body: body === undefined || status === 204 ? '' : JSON.stringify(body),
      })

    if (path === '/health/live') return reply(200, { status: 'Healthy' })
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
          accessibleBranches: tenant ? tenants[tenant]!.branches.filter((b) => !scopedBranches || scopedBranches.has(b.id)).map(({ id, name }) => ({ id, name })) : [],
          memberships: active.map((m) => ({ tenantId: m.tenantId, tenantName: tenants[m.tenantId]!.name, branchId: m.branchId, branchName: null, role: m.role })),
        },
        tenant,
      )
    }
    if (method === 'GET' && path === '/api/v1/me/invitations') {
      const invitations = user.memberships
        .filter((m) => m.status === 'invited')
        .map((m) => ({ membershipId: m.id, tenantId: m.tenantId, tenantName: tenants[m.tenantId]!.name, branchId: m.branchId, role: m.role, invitedAt: m.createdAt }))
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
    const REG_WRITE = ['tenant_admin', 'doctor', 'nurse', 'receptionist']
    const FRONT_DESK = ['tenant_admin', 'receptionist', 'nurse']
    const has = (allowed: string[], held: string[] = roles) => held.some((r) => allowed.includes(r))
    const problem = (status: number, code?: string, extra: Record<string, unknown> = {}) => reply(status, { title: code ?? 'Error', status, ...(code ? { code } : {}), ...extra }, tenant)
    const notFound = () => problem(404, 'not_found')
    const forbidden = () => problem(403, 'forbidden')

    const livePatients = this.patients.filter((p) => p.tenantId === tenant && !p.deletedAt)
    const dto = ({ tenantId: _t, email: _e, ...p }: MockPatient) => p
    const detailDto = ({ tenantId: _t, ...p }: MockPatient) => p
    const page = (items: unknown[]) => ({ items, page: 1, pageSize: 25, totalCount: items.length })
    const patientMatch = /^\/api\/v1\/patients\/([^/]+)$/.exec(path)
    const restoreMatch = /^\/api\/v1\/patients\/([^/]+)\/restore$/.exec(path)

    if (method === 'GET' && path === '/api/v1/patients') {
      if (url.searchParams.has('search')) {
        return reply(400, { title: 'Validation', status: 400, errors: { search: ['The search query parameter is no longer supported. Use POST /api/v1/patients/search with a JSON body.'] } }, tenant)
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
          (body.phone === undefined || normalizePhone(p.phone) === normalizePhone(String(body.phone))) &&
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
          if (body.dateOfBirth && p.dateOfBirth === body.dateOfBirth && norm(p.firstName) === norm(body.firstName) && norm(p.lastName) === norm(body.lastName)) reasons.push('name_dob')
          if (normalizePhone(p.phone) && normalizePhone(p.phone) === normalizePhone(body.phone as string)) reasons.push('phone')
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
      const mrn = String(body.mrn).toUpperCase()
      if (this.patients.some((p) => p.tenantId === tenant && p.mrn === mrn)) return problem(409, 'duplicate_mrn')
      const created: MockPatient = { id: uuid('ab000000'), tenantId: tenant, mrn, firstName: String(body.firstName), lastName: String(body.lastName), dateOfBirth: (body.dateOfBirth as string) ?? null, sex: String(body.sex ?? 'unknown'), registeredBranchId: String(body.registeredBranchId), phone: (body.phone as string) ?? null, email: (body.email as string) ?? null, deletedAt: null }
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
        if (!has(REG_WRITE, rolesAt(patient.registeredBranchId))) return forbidden()
        if ('mrn' in body) return reply(400, { title: 'Validation', status: 400, errors: { mrn: ['MRN is immutable.'] } }, tenant)
        if (dobInFuture(body.dateOfBirth, String(body.registeredBranchId ?? patient.registeredBranchId))) return dobProblem()
        Object.assign(patient, body)
        return reply(200, detailDto(patient), tenant)
      }
      if (method === 'DELETE') {
        const branchRoles = rolesAt(patient.registeredBranchId)
        if (!branchRoles.includes('tenant_admin') && !branchRoles.includes('receptionist')) return forbidden()
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
      return { ...strip(row), patient: p ? { id: p.id, mrn: p.mrn, firstName: p.firstName, lastName: p.lastName } : null }
    }
    if (method === 'GET' && path === '/api/v1/practitioners') {
      const branchId = url.searchParams.get('branchId')
      if (branchId && this.legacyApi) return reply(400, { title: 'Validation', status: 400, errors: { branchId: ['Unknown parameter.'] } }, tenant)
      const atBranch = branchId ? new Set(schedules.filter((s) => s.branchId === branchId && s.isActive).map((s) => s.practitionerId)) : null
      return reply(200, practitioners.filter((p) => p.tenantId === tenant && (url.searchParams.get('activeOnly') !== 'true' || p.isActive) && (!atBranch || atBranch.has(p.id))).map(strip), tenant)
    }
    if (method === 'GET' && path === '/api/v1/schedules') {
      const branchId = url.searchParams.get('branchId')
      return reply(200, schedules.filter((s) => s.tenantId === tenant && (!branchId || s.branchId === branchId)).map(strip), tenant)
    }
    if (method === 'GET' && path === '/api/v1/slots') {
      if (!has(REG_READ)) return forbidden()
      const branchId = url.searchParams.get('branchId')!
      const practitionerId = url.searchParams.get('practitionerId')
      const from = url.searchParams.get('from')!
      const to = url.searchParams.get('to')!
      const slots: unknown[] = []
      for (let d = from; d <= to; d = addDays(d, 1)) {
        for (const s of schedules.filter((x) => x.tenantId === tenant && x.branchId === branchId && x.weekday === isoWeekday(d) && (!practitionerId || x.practitionerId === practitionerId))) {
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
    const apptAction = /^\/api\/v1\/appointments\/([^/]+)\/(cancel|check-in)$/.exec(path)
    if (method === 'GET' && path === '/api/v1/appointments') {
      if (!has(REG_READ)) return forbidden()
      const q = url.searchParams
      const items = this.appointments
        .filter((a) => a.tenantId === tenant && (!q.get('branchId') || a.branchId === q.get('branchId')) && (!q.get('practitionerId') || a.practitionerId === q.get('practitionerId')) && (!q.get('from') || a.endsAt > new Date(q.get('from')!).toISOString()) && (!q.get('to') || a.startsAt < new Date(q.get('to')!).toISOString()))
        .sort((a, b) => a.startsAt.localeCompare(b.startsAt))
        .map(withPatient)
      return reply(200, { items, page: 1, pageSize: Number(q.get('pageSize') ?? 25), totalCount: items.length }, tenant)
    }
    if (method === 'POST' && path === '/api/v1/appointments') {
      const branchId = String(body.branchId)
      if (!canAccessBranch(branchId) || !has(REG_WRITE, rolesAt(branchId))) return forbidden()
      // Contract v4: foreign/unknown/soft-deleted patient or practitioner → 404 (was 400 invalid_reference).
      if (!livePatients.some((p) => p.id === body.patientId) || !practitioners.some((p) => p.tenantId === tenant && p.id === body.practitionerId)) return notFound()
      const startsAt = new Date(String(body.startsAt)).toISOString()
      const endsAt = new Date(String(body.endsAt)).toISOString()
      if (this.appointments.some((a) => a.practitionerId === body.practitionerId && BLOCKING.includes(a.status) && a.startsAt < endsAt && a.endsAt > startsAt)) {
        return problem(409, 'appointment_overlap', { detail: 'The practitioner already has an appointment at that time.' })
      }
      const created: MockAppointment = { id: uuid('a2000000'), tenantId: tenant, branchId, practitionerId: String(body.practitionerId), patientId: String(body.patientId), startsAt, endsAt, status: 'booked', reason: (body.reason as string) ?? null, cancelReason: null }
      this.appointments.push(created)
      return reply(201, withPatient(created), tenant)
    }
    if (method === 'POST' && apptAction) {
      const appt = this.appointments.find((a) => a.tenantId === tenant && a.id === apptAction[1])
      if (!appt) return notFound()
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
      if (!has(REG_READ) || !canAccessBranch(branchId)) return forbidden()
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

    if (method === 'GET' && path === '/api/v1/branches') {
      return reply(200, tenants[tenant]!.branches.map((b) => ({ ...b, timezone: this.branchZone(b.id), isActive: true })), tenant)
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
    return reply(404, { title: 'Not found', status: 404 }, tenant)
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
