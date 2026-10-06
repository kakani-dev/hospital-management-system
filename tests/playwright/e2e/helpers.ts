import { expect, type APIRequestContext, type Page } from '@playwright/test'
import pg from 'pg'

export const PASSWORD = process.env.E2E_PASSWORD ?? 'synthetic-demo-pass'
const AUTH_URL = process.env.E2E_AUTH_URL ?? 'http://localhost:54321'
const ADMIN_DB_URL = process.env.E2E_ADMIN_DB_URL ?? 'postgresql://postgres:postgres@localhost:5432/hms_e2e'

/** Synthetic seed users (supabase/seed.sql). */
export const users = {
  alphaAdmin: 'admin@alpha.example',
  alphaReception: 'reception@alpha.example',
  alphaLab: 'lab@alpha.example',
  betaAdmin: 'admin@beta.example',
  betaDoctor: 'doctor@beta.example',
  outsider: 'outsider@example.test',
  consultant: 'consultant@shared.example',
} as const

export const ids = {
  alpha: '11111111-1111-4111-8111-111111111111',
  beta: '22222222-2222-4222-8222-222222222222',
  alphaMain: 'a1111111-0000-4000-8000-000000000001',
  alphaEast: 'a1111111-0000-4000-8000-000000000002',
  betaMain: 'b2222222-0000-4000-8000-000000000001',
  alphaPatient: 'aa000000-0000-4000-8000-000000000001',
  betaPatient: 'bb000000-0000-4000-8000-000000000001',
}

export const tenantNames = { alpha: 'Demo Alpha Hospital (synthetic)', beta: 'Demo Beta Clinic (synthetic)' }

export const unique = (prefix: string) => `${prefix}-${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`.slice(0, 32)

export async function signIn(page: Page, email: string = users.alphaAdmin, password = PASSWORD) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await expect(page.getByTestId('user-email')).toHaveText(email)
}

/** Gets an access token straight from the (mock) auth server, for API-level attack tests. */
export async function tokenFor(request: APIRequestContext, email: string): Promise<string> {
  const response = await request.post(`${AUTH_URL}/auth/v1/token?grant_type=password`, { data: { email, password: PASSWORD } })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).access_token as string
}

export const bearer = (token: string) => ({ Authorization: `Bearer ${token}` })

/** Response header with the tenant the API resolved (absent when no tenant is resolved). */
export const TENANT_HEADER = 'x-hms-tenant'

/** POST /api/v1/members always answers 202 with this body (no account enumeration, review B1). */
export const ADD_MEMBER_GENERIC_MESSAGE = 'If an account exists for that email, an invitation has been sent.'

export interface Invitation {
  membershipId: string
  tenantId: string
  tenantName: string
  branchId: string | null
  role: string
  invitedAt: string
}

/** Invites `body.email` into the admin's resolved tenant through the API (expect 202 + generic message). */
export async function inviteMember(
  request: APIRequestContext,
  adminEmail: string,
  body: { email: string; role: string; branchId?: string | null },
) {
  const token = await tokenFor(request, adminEmail)
  return request.post('/api/v1/members', { headers: bearer(token), data: body })
}

/** GET /api/v1/me/invitations as `email` (works without a resolved tenant). */
export async function pendingInvitations(request: APIRequestContext, email: string): Promise<Invitation[]> {
  const response = await request.get('/api/v1/me/invitations', { headers: bearer(await tokenFor(request, email)) })
  expect(response.status()).toBe(200)
  return (await response.json()) as Invitation[]
}

/** Accepts `email`'s pending invitation to `tenantId` through the API (204; 404 if not acceptable). */
export async function acceptInvitation(request: APIRequestContext, email: string, tenantId: string) {
  const token = await tokenFor(request, email)
  const invitations = (await (await request.get('/api/v1/me/invitations', { headers: bearer(token) })).json()) as Invitation[]
  const invitation = invitations.find((i) => i.tenantId === tenantId)
  expect(invitation, `pending invitation for ${email} to ${tenantId}`).toBeTruthy()
  return request.post(`/api/v1/me/invitations/${invitation!.membershipId}/accept`, { headers: bearer(token) })
}

/** POST /api/v1/patients/search (GET ?search= is a 400 now: PHI must not be in URLs). */
export function searchPatients(request: APIRequestContext, token: string, search: string, pageSize = 25) {
  return request.post('/api/v1/patients/search', { headers: bearer(token), data: { search, page: 1, pageSize } })
}

/**
 * The web app keeps the Supabase session in sessionStorage (per tab), so `context.newPage()` starts
 * signed OUT. A tab opened with window.open from a signed-in tab gets a copy of its sessionStorage,
 * like a user opening a link in a new tab — use this for multi-tab scenarios (M3).
 */
export async function openSecondTab(page: Page, path = '/'): Promise<Page> {
  const [popup] = await Promise.all([page.context().waitForEvent('page'), page.evaluate((p) => window.open(p, '_blank'), path)])
  await popup.waitForLoadState()
  return popup
}

/** Resets a user's stored active context (identity.user_profiles) so specs start from a known state. */
export async function resetActiveContext(email: string) {
  await withAdminDb((c) =>
    c.query(
      `update identity.user_profiles set active_tenant_id = null, active_branch_id = null
        where id = (select id from auth.users where email = $1)`,
      [email],
    ),
  )
}

/** Creates a synthetic auth user with no memberships (as the DB owner, like GoTrue sign-up would). */
export async function createSyntheticUser(label: string): Promise<string> {
  const email = `${unique(label)}@synthetic.example`.toLowerCase()
  await withAdminDb((c) => c.query('insert into auth.users (id, email) values (gen_random_uuid(), $1)', [email]))
  return email
}

async function withAdminDb<T>(fn: (c: pg.Client) => Promise<T>): Promise<T> {
  const client = new pg.Client({ connectionString: ADMIN_DB_URL })
  await client.connect()
  try {
    return await fn(client)
  } finally {
    await client.end()
  }
}
