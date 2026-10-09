import { expect, test, type Page } from '@playwright/test'
import { MockBackend, PASSWORD, SERVICE_UNAVAILABLE, ids, patientIds, signIn } from './mock-backend'

/**
 * Cold-start resilience against the mocked API (CTO answers: cold service → 503 service_unavailable
 * + Retry-After: 5 from the edge; GETs retried with backoff, writes never auto-retried).
 * playwright.mocked.config.ts shrinks the knobs: banner after 1 s, write timeout 3 s, backoff ≤ 1 s.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })
const calls = (method: string, path: string) => backend.calls.filter((c) => c.method === method && c.path === path)

test('warm-up: one unauthenticated GET /api/v1/warmup on app load and one per sign-in', async ({ page }) => {
  await page.goto('/login')
  await expect.poll(() => backend.warmups).toBe(1)
  await page.getByLabel('Email').fill('admin@alpha.example')
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('heading', { name: 'Dashboard' }).waitFor()
  await expect.poll(() => backend.warmups).toBe(2)
  // the second one follows the password grant
  const order = backend.calls.map((c) => (c.path === '/api/v1/warmup' ? 'warmup' : c.path === '/auth/v1/token' ? 'token' : null)).filter(Boolean)
  expect(order.slice(0, 3)).toEqual(['warmup', 'token', 'warmup'])
  for (const c of calls('GET', '/api/v1/warmup')) expect(c.headers['authorization']).toBeUndefined()
  expect(backend.calls.some((c) => c.path.startsWith('/health/ready'))).toBe(false)
})

test('a slow response shows the waking banner, which clears when the data arrives', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  backend.fault({ method: 'GET', path: '/api/v1/patients', delayMs: 2_500 })
  const banner = page.getByTestId('waking-banner')
  await expect(banner).toHaveCount(0)
  await nav(page, 'Patients').click()
  await expect(banner).toContainText('Waking the server')
  await expect(banner).toHaveAttribute('data-phase', 'waking')
  await expect(page.getByTestId('patient-row').first()).toBeVisible()
  await expect(banner).toHaveCount(0)
})

test('a 503 + Retry-After from a cold service is retried until it succeeds (no error, no logout)', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  backend.fault({ method: 'GET', path: '/api/v1/patients', times: 3, ...SERVICE_UNAVAILABLE })
  await nav(page, 'Patients').click()
  await expect(page.getByTestId('patient-row').first()).toBeVisible()
  expect(calls('GET', '/api/v1/patients')).toHaveLength(4)
  await expect(page.getByRole('alert')).toHaveCount(0)
  await expect(page.getByTestId('user-email')).toHaveText('reception@alpha.example')
})

test('a cold /me on reload keeps the session and shows no false "no branch access"', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  backend.fault({ method: 'GET', path: '/api/v1/me', times: 2, ...SERVICE_UNAVAILABLE })
  await page.goto('/reception/check-in')
  await expect(page.getByRole('heading', { name: 'Reception check-in' })).toBeVisible()
  await expect(page.getByTestId('checkin-appointment')).toContainText('Synthetic-Alpha, Asha')
  await expect(page.getByText(/do not have access to any branch/i)).toHaveCount(0)
  await expect(page).toHaveURL(/\/reception\/check-in$/)
})

test('a walk-in POST that times out is not auto-retried: Retry button, then the token is issued', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await nav(page, 'Check-in').click()
  backend.fault({ method: 'POST', path: '/api/v1/queue/walk-in', hang: true })
  const walkIn = page.getByRole('form', { name: 'Walk-in check-in' })
  await walkIn.getByLabel('Find walk-in patient').fill('ALP-0002')
  await walkIn.getByRole('option', { name: /Synthetic-Alpha, Ravi/ }).click()
  await walkIn.getByRole('button', { name: 'Issue walk-in token' }).click()
  await expect(walkIn.getByRole('button', { name: 'Issuing…' })).toBeVisible()

  const retry = page.getByTestId('retry-alert')
  await expect(retry).toContainText('may still have been saved', { timeout: 10_000 })
  expect(calls('POST', '/api/v1/queue/walk-in')).toHaveLength(1)
  await retry.getByRole('button', { name: 'Retry' }).click()
  await expect(page.getByTestId('token-number')).toHaveText('1')
  await expect(retry).toHaveCount(0)
  expect(calls('POST', '/api/v1/queue/walk-in')).toHaveLength(2)
  expect(backend.queue.filter((q) => q.branchId === ids.alphaMain)).toHaveLength(1)
})

test('a 503 on check-in says nothing was saved and Retry checks the patient in', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await nav(page, 'Check-in').click()
  backend.fault({ method: 'POST', path: /\/check-in$/, ...SERVICE_UNAVAILABLE })
  await page.getByRole('button', { name: 'Check in Asha Synthetic-Alpha at 09:30' }).click()
  const retry = page.getByTestId('retry-alert')
  await expect(retry).toContainText('Nothing was saved')
  await retry.getByRole('button', { name: 'Retry' }).click()
  await expect(page.getByTestId('token-number')).toHaveText('1')
  expect(backend.calls.filter((c) => c.method === 'POST' && c.path.endsWith('/check-in'))).toHaveLength(2)
})

test('queue moves are optimistic; a failed move rolls back', async ({ page }) => {
  backend.issueToken(ids.alphaMain, patientIds.asha)
  await signIn(page, 'reception@alpha.example')
  await nav(page, 'OPD queue').click()
  backend.fault({ method: 'PATCH', path: /^\/api\/v1\/queue\//, delayMs: 1_500, status: 500, body: { title: 'Server error', status: 500 } })
  await page.getByRole('button', { name: 'Call in token 1' }).click()
  // moved at once, marked as saving
  await expect(page.getByTestId('queue-in_consultation').getByTestId('queue-entry-saving')).toBeVisible()
  // the server rejects it → back to waiting
  await expect(page.getByTestId('queue-waiting').getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
  await expect(page.getByRole('alert')).toBeVisible()
  await page.getByRole('button', { name: 'Call in token 1' }).click()
  await expect(page.getByTestId('queue-in_consultation').getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
})
