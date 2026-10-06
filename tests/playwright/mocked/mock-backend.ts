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

const patients = [
  { id: 'aa000000-0000-4000-8000-000000000001', tenantId: ids.alpha, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female', registeredBranchId: ids.alphaMain },
  { id: 'aa000000-0000-4000-8000-000000000002', tenantId: ids.alpha, mrn: 'ALP-0002', firstName: 'Ravi', lastName: 'Synthetic-Alpha', dateOfBirth: '1985-05-05', sex: 'male', registeredBranchId: ids.alphaEast },
  { id: 'bb000000-0000-4000-8000-000000000001', tenantId: ids.beta, mrn: 'BET-0001', firstName: 'Meera', lastName: 'Synthetic-Beta', dateOfBirth: '1970-07-07', sex: 'female', registeredBranchId: ids.betaMain },
]

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
    const body = (request.postDataJSON() ?? {}) as Record<string, unknown>

    // Tenant-independent endpoints (work for a signed-in user with no tenant).
    if (method === 'GET' && path === '/api/v1/me') {
      return reply(
        200,
        {
          userId: user.id,
          email: user.email,
          activeTenantId: tenant,
          activeBranchId: null,
          roles,
          accessibleBranches: tenant ? tenants[tenant]!.branches.map(({ id, name }) => ({ id, name })) : [],
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
    const tenantPatients = patients.filter((p) => p.tenantId === tenant).map(({ tenantId: _t, ...p }) => p)
    const page = (items: unknown[]) => ({ items, page: 1, pageSize: 25, totalCount: items.length })

    if (method === 'GET' && path === '/api/v1/patients') {
      if (url.searchParams.has('search')) {
        return reply(400, { title: 'Validation', status: 400, errors: { search: ['The search query parameter is no longer supported. Use POST /api/v1/patients/search with a JSON body.'] } }, tenant)
      }
      return reply(200, page(tenantPatients), tenant)
    }
    if (method === 'POST' && path === '/api/v1/patients/search') {
      const term = String(body.search ?? '').trim()
      if (term.length > 100) return reply(400, { title: 'Validation', status: 400, errors: { search: ['Search term must be at most 100 characters.'] } }, tenant)
      const t = term.toLowerCase()
      return reply(200, page(tenantPatients.filter((p) => [p.mrn, p.firstName, p.lastName].some((v) => v.toLowerCase().includes(t)))), tenant)
    }
    if (method === 'GET' && path === '/api/v1/branches') {
      return reply(200, tenants[tenant]!.branches.map((b) => ({ ...b, timezone: 'Asia/Kolkata', isActive: true })), tenant)
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
