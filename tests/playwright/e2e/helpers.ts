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
