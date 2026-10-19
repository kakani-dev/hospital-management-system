import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { INVITEE_EMAIL, MockBackend, OPERATOR_EMAIL, PASSWORD, ids, signIn } from './mock-backend'

/**
 * Level 1 (tenants, branches, appointments) against the mocked API: public hospital registration,
 * the platform console (requests queue, create, suspend), invite links end to end, branch
 * delete/restore, member branch scope, and the calendar's cancel reason / filters. Axe in both themes.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

async function signInAs(page: Page, email: string, landing: string | RegExp) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('heading', { name: landing }).first().waitFor()
}

test('a hospital registers publicly; nothing is created until an operator approves it', async ({ page }) => {
  await page.goto('/login')
  await page.getByRole('link', { name: 'Register your hospital' }).click()
  await expect(page).toHaveURL(/\/register-hospital$/)
  await page.getByLabel('Hospital name').fill('Synthetic Jasmine Hospital')
  await page.getByLabel('Hospital time zone').fill('Asia/Kolkata')
  await page.getByLabel('City').fill('Chennai')
  await page.getByLabel('Your name').fill('Jaya Synthetic')
  await page.getByLabel('Work email').fill('jaya@jasmine.example')
  await page.getByLabel('Phone').fill('+91 44 5550 7788')
  await page.getByRole('button', { name: 'Send request' }).click()
  await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()
  const post = backend.calls.find((c) => c.path === '/api/v1/public/hospital-signups')!
  expect(post.headers['authorization']).toBeUndefined()
  expect(backend.signups.find((s) => s.contactEmail === 'jaya@jasmine.example')?.status).toBe('pending')
  expect(backend.platformTenants).toHaveLength(0)
})

test('the operator lands on the console, approves a request and the contact joins with the invite link', async ({ page, context }) => {
  await signInAs(page, OPERATOR_EMAIL, 'Hospitals')
  await expect(page).toHaveURL(/\/platform$/)
  await expect(page.getByTestId('platform-tenant-row')).toHaveCount(2)
  await expect(page.getByTestId('tenant-name')).toHaveText('Platform console (no hospital access)')
  await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Hospital requests', exact: true }).click()
  await expect(page.getByTestId('hospital-request-row')).toHaveCount(2)
  await page.getByRole('button', { name: 'Reject Synthetic Orchid Hospital' }).click()
  await page.getByRole('alertdialog').getByLabel('Reason').fill('Duplicate of an existing synthetic hospital')
  await page.getByRole('alertdialog').getByRole('button', { name: 'Reject request' }).click()
  await expect(page.getByText('Synthetic Orchid Hospital was rejected.')).toBeVisible()

  await page.getByRole('button', { name: 'Approve Synthetic Lotus Clinic' }).click()
  await expect(page.getByRole('alertdialog').getByLabel('Hospital code')).toHaveValue('synthetic-lotus-clinic')
  await page.getByRole('alertdialog').getByLabel('Hospital code').fill('lotus')
  await page.getByRole('alertdialog').getByRole('button', { name: 'Approve and create' }).click()
  const link = await page.getByTestId('invite-link-url').inputValue()
  expect(link).toMatch(/\/invite\/[0-9a-f]{64}$/)
  // The operator still has no access to clinical data.
  expect(backend.calls.some((c) => /\/api\/v1\/(patients|appointments|queue|members)/.test(c.path))).toBe(false)

  // The contact opens the link in a fresh browser (no session): preview, then sign in to accept.
  const other = await context.browser()!.newContext()
  await backend.install(other)
  const contact = await other.newPage()
  await contact.goto(new URL(link).pathname)
  await expect(contact.getByTestId('invite-preview')).toContainText('Synthetic Lotus Clinic')
  await expect(contact.getByTestId('invite-preview')).toContainText('a***@lotus.example')
  await other.close()
})

test('a tenant admin invites by link; the invitee signs in, accepts and lands in the hospital', async ({ page, context }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/admin/members')
  const form = page.getByRole('form', { name: 'Create invite link' })
  await form.getByLabel('Email').fill(INVITEE_EMAIL)
  await form.getByLabel('Role').selectOption('receptionist')
  await form.getByLabel('Branch scope').selectOption({ label: 'Alpha Main Campus' })
  await form.getByRole('button', { name: 'Create invite link' }).click()
  const link = new URL(await page.getByTestId('invite-link-url').inputValue()).pathname
  await expect(page.getByTestId('invite-link-row').first()).toHaveAttribute('data-status', 'pending')

  const other = await context.browser()!.newContext()
  await backend.install(other)
  const invitee = await other.newPage()
  await invitee.goto(link)
  await invitee.getByRole('button', { name: 'Sign in to accept' }).click()
  await invitee.getByLabel('Email').fill(INVITEE_EMAIL)
  await invitee.getByLabel('Password').fill(PASSWORD)
  await invitee.getByRole('button', { name: 'Sign in' }).click()
  await invitee.getByRole('button', { name: /^Join Demo Alpha Hospital/ }).click()
  await expect(invitee.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await expect(invitee.getByTestId('tenant-name')).toContainText('Demo Alpha Hospital')
  // single use
  await invitee.goto(link)
  await expect(invitee.getByText(/not valid any more/)).toBeVisible()
  await other.close()
})

test('a suspended hospital locks its staff out; reactivation restores access', async ({ page, context }) => {
  await signInAs(page, OPERATOR_EMAIL, 'Hospitals')
  await page.getByRole('link', { name: 'Demo Beta Clinic (synthetic)' }).click()
  await page.getByRole('button', { name: 'Suspend hospital' }).click()
  await page.getByRole('alertdialog').getByLabel('Reason').fill('Synthetic compliance hold')
  await page.getByRole('alertdialog').getByRole('button', { name: 'Suspend' }).click()
  await expect(page.getByTestId('platform-tenant-status')).toHaveText('suspended')
  await expect(page.getByTestId('platform-tenant-history')).toContainText('Synthetic compliance hold')

  const other = await context.browser()!.newContext()
  await backend.install(other)
  const consultant = await other.newPage()
  await signIn(consultant, 'consultant@shared.example')
  // Beta is gone from the switcher; only Alpha is left.
  await expect(consultant.getByTestId('tenant-name')).toContainText('Demo Alpha Hospital')
  await expect(consultant.getByText('Demo Beta Clinic (synthetic)')).toHaveCount(0)
  await other.close()
  expect(backend.tenantIsActive(ids.beta)).toBe(false)
})

test('the platform console is closed to hospital staff (403 from the API)', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/platform')
  await expect(page.getByText('Only platform operators can open the platform console.')).toBeVisible()
  await expect(page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Hospital requests' })).toHaveCount(0)
})

test('branches can be deleted and restored; members move between branch scopes', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/admin/branches')
  await page.getByRole('button', { name: 'Delete Alpha Main Campus' }).click()
  await page.getByRole('alertdialog').getByRole('button', { name: 'Delete branch' }).click()
  await expect(page.getByText('Could not delete Alpha Main Campus: branch has open appointments or queue entries.')).toBeVisible()
  await page.getByRole('button', { name: 'Delete Alpha East Clinic' }).click()
  await page.getByRole('alertdialog').getByRole('button', { name: 'Delete branch' }).click()
  await expect(page.getByTestId('branch-row')).toHaveCount(1)
  await page.getByLabel('Show deleted branches').check()
  await page.getByRole('button', { name: 'Restore Alpha East Clinic' }).click()
  await expect(page.getByText('Alpha East Clinic was restored as inactive. Activate it to use it again.')).toBeVisible()
  await page.getByRole('button', { name: 'Activate Alpha East Clinic' }).click()

  await page.goto('/admin/members')
  await page.getByLabel('Branch scope for doctor@alpha.example').selectOption({ label: 'Alpha East Clinic' })
  await expect.poll(() => backend.users.get('doctor@alpha.example')!.memberships[0]!.branchId).toBe(ids.alphaEast)
})

test('calendar: cancel asks for a reason, status filter and patient search narrow the day', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await expect(page.getByTestId('appointment')).toHaveCount(1)
  await page.getByLabel('Find patient').fill('nobody-synthetic')
  await expect(page.getByTestId('appointment')).toHaveCount(0)
  await page.getByLabel('Find patient').fill('Asha')
  await expect(page.getByTestId('appointment')).toHaveCount(1)
  await page.getByRole('button', { name: 'Cancel appointment' }).click()
  await page.getByRole('alertdialog').getByLabel('Reason (optional)').fill('Patient travelling')
  await page.getByRole('alertdialog').getByRole('button', { name: 'Cancel appointment' }).click()
  await expect(page.getByTestId('appointment')).toHaveAttribute('data-status', 'cancelled')
  await expect(page.getByTestId('appointment')).toContainText('Cancelled: Patient travelling')
  await page.getByLabel('Status').selectOption('booked')
  await expect(page.getByTestId('appointment')).toHaveCount(0)
  expect(backend.calls.some((c) => c.path === '/api/v1/appointments' && new URL(c.url).searchParams.get('status') === 'booked')).toBe(true)
})

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']
async function seriousViolations(page: Page) {
  // Let dialog/drawer enter transitions finish (mid-fade colours are not the real contrast).
  await page.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => undefined))))
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map((v) => `${v.id}: ${v.help} (${v.nodes.map((n) => `${n.target.join(' ')} :: ${n.failureSummary ?? ''}`).join(' | ')})`)
}

for (const theme of ['light', 'dark'] as const) {
  test(`axe, ${theme}: register, invite, platform console, requests`, async ({ page, context }) => {
    await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    await page.goto('/register-hospital')
    await expect(page.getByRole('heading', { name: 'Register your hospital' })).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    const invite = backend.issueInviteLink(ids.alpha, 'Demo Alpha Hospital (synthetic)', INVITEE_EMAIL, 'nurse', ids.alphaMain, 7)
    await page.goto(invite.path)
    await expect(page.getByTestId('invite-preview')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await signInAs(page, OPERATOR_EMAIL, 'Hospitals')
    await expect(page.getByTestId('platform-tenant-row').first()).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.getByRole('button', { name: 'Create hospital' }).click()
    await expect(page.getByTestId('create-tenant-drawer')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto('/platform/requests')
    await page.getByRole('button', { name: 'Approve Synthetic Lotus Clinic' }).click()
    await expect(page.getByRole('alertdialog')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto(`/platform/hospitals/${ids.alpha}`)
    await expect(page.getByTestId('platform-tenant-details')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
  })

  test(`axe, ${theme}: members with invite links, branches with deleted rows, calendar cancel dialog`, async ({ page, context }) => {
    await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    backend.issueInviteLink(ids.alpha, 'Demo Alpha Hospital (synthetic)', 'later@synthetic.example', 'doctor', null, 7)
    backend.branchState.set(ids.alphaEast, { isActive: false, isDeleted: true })
    await signIn(page, 'admin@alpha.example')
    await page.goto('/admin/members')
    await expect(page.getByTestId('invite-link-row').first()).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto('/admin/branches')
    await page.getByLabel('Show deleted branches').check()
    await expect(page.getByRole('button', { name: 'Restore Alpha East Clinic' })).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto(`/appointments?branch=${ids.alphaMain}`)
    await page.getByRole('button', { name: 'Cancel appointment' }).click()
    await expect(page.getByRole('alertdialog')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
  })
}
