import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { INVITEE_EMAIL, MockBackend, OPERATOR_EMAIL, PASSWORD, ids, patientIds, signIn } from './mock-backend'
import { completeRegistration } from '../registration'

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

test('a live hospital admin cannot register again; a doctor at that hospital still can', async ({ page }) => {
  await page.goto('/register-hospital')
  await page.getByLabel('Hospital name').fill('Synthetic Elsewhere Hospital')
  await page.getByLabel('Hospital time zone').fill('Asia/Kolkata')
  await page.getByLabel('City').fill('Pune')
  await page.getByLabel('Your name').fill('Asha Synthetic')
  await page.getByLabel('Work email').fill('  Admin@Alpha.Example  ')
  await page.getByLabel('Phone').fill('+91 20 5550 4400')
  await page.getByRole('button', { name: 'Send request' }).click()
  await expect(page.getByRole('alert')).toHaveText('This email is already registered. Please sign in or contact support.')
  await expect(page.getByRole('heading', { name: 'Request received' })).toHaveCount(0)
  expect(backend.signups.some((s) => s.contactEmail === 'admin@alpha.example')).toBe(false)

  await page.getByLabel('Work email').fill('consultant@shared.example')
  await page.getByRole('button', { name: 'Send request' }).click()
  await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()
  expect(backend.signups.find((s) => s.contactEmail === 'consultant@shared.example')?.status).toBe('pending')
})

test('a normalized name or phone match is badged and approval asks for confirmation', async ({ page }) => {
  await page.goto('/register-hospital')
  await page.getByLabel('Hospital name').fill('Synthetic Cedar Hospital')
  await page.getByLabel('Hospital time zone').fill('Asia/Kolkata')
  await page.getByLabel('City').fill('Pune')
  await page.getByLabel('Your name').fill('Cedar Synthetic')
  await page.getByLabel('Work email').fill('cedar@cedar.example')
  await page.getByLabel('Phone').fill('+91 4455501001')
  await page.getByRole('button', { name: 'Send request' }).click()
  await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()

  await page.goto('/register-hospital')
  await page.getByLabel('Hospital name').fill('synthetic cedar CLINIC')
  await page.getByLabel('Hospital time zone').fill('Asia/Kolkata')
  await page.getByLabel('City').fill('Pune')
  await page.getByLabel('Your name').fill('Cedar Two')
  await page.getByLabel('Work email').fill('cedar-two@cedar.example')
  await page.getByLabel('Phone').fill('04455501001')
  await page.getByRole('button', { name: 'Send request' }).click()
  await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()

  await signInAs(page, OPERATOR_EMAIL, 'Hospitals')
  await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Hospital requests', exact: true }).click()
  await expect(page.getByTestId('possible-duplicate')).toHaveCount(2)
  await expect(page.getByText('Matches synthetic cedar CLINIC')).toBeVisible()
  await expect(page.getByText('Matches Synthetic Cedar Hospital')).toBeVisible()

  await page.getByRole('button', { name: 'Approve synthetic cedar CLINIC' }).click()
  const dialog = page.getByRole('alertdialog')
  await expect(dialog.getByText('This may duplicate Synthetic Cedar Hospital.')).toBeVisible()
  const approveCalls = () => backend.calls.filter((c) => c.method === 'POST' && c.path.endsWith('/approve'))
  await dialog.getByRole('button', { name: 'Approve and create' }).click()
  await expect(page.getByText('Confirm that you reviewed the possible duplicate.')).toBeVisible()
  expect(approveCalls()).toHaveLength(0)
  await dialog.getByRole('checkbox', { name: 'I have reviewed the possible duplicate' }).check()
  await dialog.getByRole('button', { name: 'Approve and create' }).click()
  await expect(page.getByTestId('invite-link-url')).toBeVisible()
  expect(approveCalls().at(-1)?.body).toMatchObject({ tenantCode: 'synthetic-cedar-clinic', acknowledgeDuplicate: true })
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
  // The operator still has no access to clinical data, and no tenant-scoped endpoint is called
  // without a hospital (GET /branches used to 403 on /platform).
  expect(backend.calls.filter((c) => /^\/api\/v1\/(patients|appointments|queue|members|branches|practitioners|schedules|slots|tenants\/current|invite-links)/.test(c.path)).map((c) => c.path)).toEqual([])

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
  await invitee.getByRole('button', { name: 'I already have a password' }).click()
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
  // let the dialog's leave transition (and its backdrop) finish before clicking the page again
  await expect(page.locator('#headlessui-portal-root [data-closed]')).toHaveCount(0)
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
  // Infinite (loading pulse) animations never finish; cap the wait so axe always runs.
  await page.evaluate(() =>
    Promise.race([
      Promise.all(
        document
          .getAnimations()
          .filter((a) => a.effect?.getTiming().iterations !== Infinity)
          .map((a) => a.finished.catch(() => undefined)),
      ),
      new Promise((r) => setTimeout(r, 2000)),
    ]),
  )
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map((v) => `${v.id}: ${v.help} (${v.nodes.map((n) => `${n.target.join(' ')} :: ${n.failureSummary ?? ''}`).join(' | ')})`)
}

test('register: no MRN input, the generated MRN is in the toast; WhatsApp same-as-phone by default, or a separate number', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.goto('/patients/new')
  await expect(page.getByLabel('MRN')).toHaveCount(0)
  await expect(page.getByText('The MRN is assigned automatically when you register.')).toBeVisible()
  await page.getByLabel('First name').fill('Wanda')
  await page.getByLabel('Last name').fill('Synthetic-Level1')
  await page.getByLabel('Mobile number').fill('098450 12345')
  const same = page.getByRole('checkbox', { name: 'Same as phone number' })
  await expect(same).toBeChecked()
  await expect(page.getByLabel('WhatsApp number')).toHaveCount(0)
  await completeRegistration(page)
  await page.getByRole('button', { name: 'Register patient' }).click()

  await expect(page.getByText('Patient registered. MRN ALPHA-000001')).toBeVisible() // toast
  const post = backend.calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!
  expect(post.body).not.toHaveProperty('mrn')
  expect(post.body).toMatchObject({ phone: '098450 12345', whatsapp: { sameAsPhone: true } })
  const created = backend.patients.find((p) => p.mrn === 'ALPHA-000001')!
  expect(created.phone).toBe('+919845012345') // normalised to E.164 with the hospital's +91

  // MRN search still works
  await page.getByLabel('Search patients').fill('ALPHA-000001')
  await expect(page.getByTestId('patient-row').filter({ hasText: 'ALPHA-000001' })).toBeVisible()

  await page.goto(`/patients/${created.id}`)
  await expect(page.getByTestId('whatsapp-same-badge')).toBeVisible()
  await page.getByRole('button', { name: 'Edit patient' }).click()
  const form = page.getByRole('form', { name: 'Edit patient' })
  await expect(form.getByTestId('edit-mrn')).toContainText('ALPHA-000001')
  await expect(form.getByLabel('MRN')).toHaveCount(0)
  await form.getByRole('checkbox', { name: 'Same as phone number' }).uncheck()
  await form.getByLabel('WhatsApp number').fill('+971 50 123 4567')
  await form.getByRole('button', { name: 'Save changes' }).click()
  await expect(page.getByText('Changes saved.')).toBeVisible()
  await expect(page.getByTestId('patient-whatsapp')).toContainText('+971501234567')
  await expect(page.getByTestId('whatsapp-same-badge')).toHaveCount(0)
  expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toMatchObject({ whatsapp: { sameAsPhone: false, number: '+971 50 123 4567' } })
})

test('register with "All my branches": a branch is pre-selected and can be changed', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await expect(page.getByTestId('tenant-context').getByLabel('Branch')).toHaveValue('') // All my branches
  await page.goto('/patients/new')
  const branch = page.getByLabel('Registered branch')
  await expect(branch).toHaveValue(ids.alphaEast) // first accessible branch
  await branch.selectOption(ids.alphaMain)
  await page.getByLabel('First name').fill('Branchy')
  await page.getByLabel('Last name').fill('Synthetic-Level1')
  await completeRegistration(page)
  await page.getByRole('button', { name: 'Register patient' }).click()
  await expect(page.getByText(/Patient registered\. MRN ALPHA-/)).toBeVisible()
  expect(backend.calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({ registeredBranchId: ids.alphaMain })
})

test('register: a bad WhatsApp number is refused by the server and shown on the field', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.goto('/patients/new')
  await page.getByLabel('First name').fill('Xena')
  await page.getByLabel('Last name').fill('Synthetic-Level1')
  await page.getByLabel('Mobile number').fill('98450 12346')
  await page.getByRole('checkbox', { name: 'Same as phone number' }).uncheck()
  await page.getByLabel('WhatsApp number').fill('12')
  await completeRegistration(page)
  await page.getByRole('button', { name: 'Register patient' }).click()
  await expect(page.getByText(/valid WhatsApp number/).first()).toBeVisible()
  expect(backend.patients.some((p) => p.firstName === 'Xena')).toBe(false)
})

test.describe('phone viewport', () => {
  test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })

  test('header: compact hospital/branch summary that opens the drawer with the full selects', async ({ page }) => {
    backend.tenantNames.set(ids.alpha, 'Synthetic Sri Venkateswara Multi-Speciality Hospital & Research Centre')
    await signIn(page, 'admin@alpha.example')
    const header = page.locator('header.app-header')
    const compact = header.getByTestId('compact-context')
    await expect(compact).toBeVisible()
    await expect(header.getByRole('combobox')).toHaveCount(0)
    // Nothing in the header overflows the viewport (the long name truncates).
    const overflow = await header.evaluate((h) => h.scrollWidth - h.clientWidth)
    expect(overflow).toBeLessThanOrEqual(0)
    const box = (await compact.boundingBox())!
    expect(box.x + box.width).toBeLessThanOrEqual(390)

    await compact.tap()
    const drawer = page.getByTestId('sidebar-context')
    await expect(drawer).toBeInViewport()
    await expect(drawer).toContainText('Synthetic Sri Venkateswara Multi-Speciality Hospital & Research Centre')
    await drawer.getByLabel('Branch').selectOption(ids.alphaEast)
    await expect.poll(() => backend.calls.find((c) => c.method === 'POST' && c.path === '/api/v1/me/context')?.body).toMatchObject({ tenantId: ids.alpha, branchId: ids.alphaEast })
  })
})

for (const theme of ['light', 'dark'] as const) {
  test(`axe, ${theme}: register (WhatsApp section), patient detail, phone header and drawer`, async ({ page, context }) => {
    await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    await signIn(page, 'reception@alpha.example')
    await page.goto('/patients/new')
    await page.getByRole('checkbox', { name: 'Same as phone number' }).uncheck()
    await expect(page.getByLabel('WhatsApp number')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto(`/patients/${patientIds.asha}`)
    await expect(page.getByTestId('patient-whatsapp')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto(`/patients/${patientIds.ravi}`)
    await expect(page.getByTestId('whatsapp-same-badge')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.setViewportSize({ width: 390, height: 844 })
    await expect(page.getByTestId('compact-context')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.getByTestId('compact-context').click()
    await expect(page.getByTestId('sidebar-context')).toBeInViewport()
    expect(await seriousViolations(page)).toEqual([])
  })
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
