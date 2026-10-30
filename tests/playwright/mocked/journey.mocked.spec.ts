import fs from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import { MockBackend, addDays, branchToday, practitionerIds, signIn } from './mock-backend'
import { completeRegistration } from '../registration'

/**
 * A typical reception journey (login → register patient → book → check in → queue → back to the
 * calendar and patients, with one page reload). Counts API calls per endpoint so the cache-first
 * policy can be measured; JOURNEY_OUT=<file> writes the counts as JSON.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })
const gets = () => backend.calls.filter((c) => c.method === 'GET' && c.path.startsWith('/api/'))
const key = (c: { path: string; url: string }) => `${c.path}${new URL(c.url).search}`

test('reception journey: API calls per endpoint, fresh data after every write', async ({ page }) => {
  const stages: [string, number][] = []
  const mark = (name: string) => stages.push([name, gets().length])
  const requestTimes: { url: string; at: number }[] = []
  page.on('request', (r) => {
    const u = new URL(r.url())
    if (r.method() === 'GET' && u.pathname.startsWith('/api/') && u.pathname !== '/api/v1/warmup') requestTimes.push({ url: u.pathname + u.search, at: Date.now() })
  })
  await signIn(page, 'reception@alpha.example')
  mark('login')

  // Register a patient
  await nav(page, 'Patients').click()
  await page.goto('/patients/new')
  await page.getByLabel('First name').fill('Journey')
  await page.getByLabel('Last name').fill('Synthetic-Cache')
  await page.getByLabel('Date of birth').fill('1990-01-01')
  await completeRegistration(page)
  await page.getByRole('button', { name: 'Register patient' }).click()
  await expect(page.getByText(/Patient .* registered\./)).toBeVisible()

  mark('register')
  // Book tomorrow 09:00 with Dr. Rao for the new patient
  await nav(page, 'Appointments').click()
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  const tomorrow = addDays(branchToday(), 1)
  await form.getByLabel('Appointment date').fill(tomorrow)
  await form.getByLabel('Find patient').fill('Journey')
  await form.getByRole('option', { name: /Synthetic-Cache, Journey/ }).click()
  await form.getByText('09:00', { exact: true }).click()
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  // Fresh after the write: the calendar shows the new booking, and the booked slot is gone.
  await expect(page.getByTestId('appointment').filter({ hasText: 'Synthetic-Cache, Journey' })).toContainText('09:00–09:15')
  await page.getByRole('button', { name: 'Book appointment' }).click()
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  await form.getByLabel('Appointment date').fill(tomorrow)
  await expect(form.getByText('09:15', { exact: true })).toBeVisible()
  await expect(form.getByText('09:00', { exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: 'Close booking' }).click()

  mark('book')
  // Check in today's appointment, then the queue shows the token
  await nav(page, 'Check-in').click()
  await page.getByRole('button', { name: 'Check in Asha Synthetic-Alpha at 09:30' }).click()
  await expect(page.getByTestId('token-number')).toHaveText('1')
  await nav(page, 'OPD queue').click()
  await expect(page.getByTestId('queue-waiting')).toContainText('Synthetic-Alpha, Asha')

  mark('check-in + queue')
  // Reload mid-shift, then revisit pages
  await page.reload()
  await expect(page.getByTestId('queue-waiting')).toContainText('Synthetic-Alpha, Asha')
  mark('reload')
  await nav(page, 'Dashboard').click()
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await nav(page, 'Appointments').click()
  await expect(page.getByRole('button', { name: 'Book appointment' })).toBeVisible()
  await nav(page, 'Patients').click()
  await expect(page.getByRole('heading', { name: 'Patients' })).toBeVisible()
  await page.waitForTimeout(500)
  if (process.env.JOURNEY_TRACE) console.log(gets().map((c) => c.path).join('\n'))

  mark('revisit dashboard/appointments/patients')
  const all = gets()
  const perEndpoint: Record<string, number> = {}
  for (const c of all) perEndpoint[c.path.replace(/[0-9a-f-]{36}/g, ':id')] = (perEndpoint[c.path.replace(/[0-9a-f-]{36}/g, ':id')] ?? 0) + 1
  const urls: Record<string, number> = {}
  for (const c of all) urls[key(c)] = (urls[key(c)] ?? 0) + 1
  const writes = backend.calls.filter((c) => c.method !== 'GET' && c.path.startsWith('/api/')).length
  const perStage = Object.fromEntries(stages.map(([n, c], i) => [n, c - (i ? stages[i - 1]![1] : 0)]))
  const result = { gets: all.length, perStage, writes, perEndpoint, repeatedUrls: Object.fromEntries(Object.entries(urls).filter(([, n]) => n > 1)) }
  if (process.env.JOURNEY_OUT) fs.writeFileSync(process.env.JOURNEY_OUT, JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result))

  // Cache-first: reference data is fetched once for the whole journey (incl. the reload) …
  for (const [path, max] of [['/api/v1/me', 1], ['/api/v1/me/invitations', 1], ['/api/v1/branches', 1]] as const) expect(perEndpoint[path] ?? 0, path).toBeLessThanOrEqual(max)
  for (const [url, n] of Object.entries(urls)) if (url.startsWith('/api/v1/practitioners')) expect(n, url).toBe(1)
  // … and no request is ever issued twice concurrently (in-flight dedup): same URL, < 50 ms apart.
  const byUrl = new Map<string, number[]>()
  for (const r of requestTimes) byUrl.set(r.url, [...(byUrl.get(r.url) ?? []), r.at])
  for (const [url, times] of byUrl) for (let i = 1; i < times.length; i++) expect(times[i]! - times[i - 1]!, `duplicate in-flight GET ${url}`).toBeGreaterThan(50)
})
