import { expect, test } from '@playwright/test'
import { ADD_MEMBER_GENERIC_MESSAGE, MockBackend, ids, openSecondTab, signIn } from './mock-backend'

/**
 * Web side of the PR #1 fixes against a mocked API + Auth (no backend/DB). The full-stack suite in
 * ../e2e covers the same flows against the real gateway and Postgres.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

test.describe('Minor 3: session storage and idle auto-logoff', () => {
  test('session lives in sessionStorage (survives reload, not shared with a fresh tab)', async ({ page, context }) => {
    await signIn(page, 'admin@alpha.example')
    const storage = await page.evaluate(() => ({ local: Object.keys(localStorage), session: Object.keys(sessionStorage) }))
    expect(storage.session).toContain('hms.auth')
    expect(storage.local.filter((k) => k.startsWith('hms.auth') && k !== 'hms.auth.events')).toEqual([])

    await page.reload()
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()

    const fresh = await context.newPage()
    await fresh.goto('/')
    await expect(fresh).toHaveURL(/\/login$/)
  })

  test('signs out after 15 idle minutes; activity resets the timer', async ({ page }) => {
    await page.clock.install()
    await signIn(page, 'admin@alpha.example')
    await page.clock.fastForward('10:00')
    await page.mouse.move(10, 10)
    await page.keyboard.press('Shift')
    await page.clock.fastForward('10:00')
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
    await page.clock.fastForward('05:01')
    await expect(page.getByRole('heading', { name: 'Sign in to HMS' })).toBeVisible()
    await expect(page.getByText('You were signed out after a period of inactivity')).toBeVisible()
    expect(backend.calls.some((c) => c.path === '/auth/v1/logout' && c.url.includes('scope=local'))).toBe(true)
  })
})

test.describe('M3: tenant drift and sign-out across tabs', () => {
  test('X-Hms-Tenant resolving another hospital clears the data and shows the banner', async ({ page }) => {
    await signIn(page, 'consultant@shared.example')
    await expect(page.getByLabel('Hospital')).toHaveValue(ids.alpha)
    await page.getByRole('link', { name: 'Patients' }).click()
    await expect(page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' }).first()).toBeVisible()

    // Switched on another device: the server now resolves Beta for this user.
    backend.setActiveTenant('consultant@shared.example', ids.beta)
    await page.getByLabel('Search patients').fill('Synthetic')

    await expect(page.getByTestId('tenant-switched-banner')).toBeVisible()
    await expect(page.getByLabel('Hospital')).toHaveValue(ids.beta)
    await expect(page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' })).toHaveCount(0)
    await expect(page.getByTestId('patient-row').filter({ hasText: 'BET-0001' })).toBeVisible()
  })

  test('switching hospital in one tab clears the other tab via the refreshed-token broadcast', async ({ page }) => {
    await signIn(page, 'consultant@shared.example')
    const tab2 = await openSecondTab(page, '/patients')
    await expect(tab2.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' }).first()).toBeVisible()

    await page.bringToFront()
    await page.getByLabel('Hospital').selectOption(ids.beta)
    await expect(page.getByTestId('dashboard-tenant')).toHaveText('Demo Beta Clinic (synthetic)')
    await expect(page.getByTestId('tenant-switched-banner')).toHaveCount(0) // own switch: no banner

    await tab2.bringToFront()
    await expect(tab2.getByTestId('tenant-switched-banner')).toBeVisible()
    await expect(tab2.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' })).toHaveCount(0)
  })

  test('signing out in one tab signs the other tab out', async ({ page }) => {
    await signIn(page, 'admin@alpha.example')
    const tab2 = await openSecondTab(page, '/patients')
    await expect(tab2.getByRole('heading', { name: 'Patients' })).toBeVisible()
    await page.getByRole('button', { name: 'Sign out' }).click()
    await expect(page).toHaveURL(/\/login$/)
    await expect(tab2.getByRole('heading', { name: 'Sign in to HMS' })).toBeVisible()
    expect(await tab2.evaluate(() => sessionStorage.getItem('hms.auth'))).toBeNull()
  })
})

test.describe('Minor 5: patient search', () => {
  test('debounced POST /patients/search; the term never appears in a URL', async ({ page }) => {
    await signIn(page, 'admin@alpha.example')
    await page.getByRole('link', { name: 'Patients' }).click()
    await expect(page.getByTestId('patient-row')).toHaveCount(2)
    await page.getByLabel('Search patients').pressSequentially('Ravi', { delay: 40 })
    await expect(page.getByTestId('patient-row')).toHaveCount(1)
    await expect(page.getByTestId('patient-row')).toContainText('ALP-0002')

    const searches = backend.calls.filter((c) => c.path === '/api/v1/patients/search')
    expect(searches).toHaveLength(1)
    expect(searches[0]).toMatchObject({ method: 'POST', body: { search: 'Ravi', pageSize: 25 } })
    expect(backend.calls.filter((c) => /search=|Ravi/.test(c.url))).toEqual([])
    await expect(page.getByLabel('Search patients')).toHaveAttribute('maxlength', '100')
  })
})

test.describe('B1: consent-based invitations', () => {
  test('admin gets the generic 202 message; the invitee accepts from the no-hospital dashboard', async ({ page, browser }) => {
    await signIn(page, 'admin@alpha.example')
    await page.getByRole('link', { name: 'Members' }).click()
    await page.getByLabel('Email').fill('newcomer@synthetic.example')
    await page.getByLabel('Role', { exact: true }).selectOption('nurse')
    await page.getByRole('button', { name: 'Add member' }).click()
    await expect(page.getByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeVisible()
    await expect(page.getByTestId('member-row').filter({ hasText: 'newcomer@synthetic.example' })).toHaveCount(0)

    // Unknown email: exactly the same answer (no account enumeration).
    await page.getByLabel('Email').fill('nobody-here@synthetic.example')
    await page.getByRole('button', { name: 'Add member' }).click()
    await expect(page.getByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeVisible()
    await expect(page.getByText(/no user|signed up/i)).toHaveCount(0)

    // tenant_admin is tenant-wide: the branch scope collapses to "All branches".
    await page.getByLabel('Branch scope').selectOption({ label: 'Alpha East Clinic' })
    await page.getByLabel('Role', { exact: true }).selectOption('tenant_admin')
    await expect(page.getByLabel('Branch scope')).toHaveValue('')
    await expect(page.getByLabel('Branch scope').locator('option')).toHaveText(['All branches'])

    const inviteeContext = await browser.newContext()
    await backend.install(inviteeContext)
    const invitee = await inviteeContext.newPage()
    await signIn(invitee, 'newcomer@synthetic.example')
    await expect(invitee.getByTestId('tenant-name')).toHaveText('No hospital memberships')
    const row = invitee.getByTestId('invitation-row')
    await expect(row).toContainText('Demo Alpha Hospital (synthetic)')
    await invitee.getByRole('button', { name: 'Accept invitation to Demo Alpha Hospital (synthetic) as nurse' }).click()
    await expect(invitee.getByText('You joined Demo Alpha Hospital (synthetic) as nurse.')).toBeVisible()
    await expect(row).toHaveCount(0)
    await expect(invitee.getByTestId('dashboard-tenant')).toHaveText('Demo Alpha Hospital (synthetic)')
    await inviteeContext.close()

    await page.reload()
    await expect(page.getByTestId('member-row').filter({ hasText: 'newcomer@synthetic.example' })).toContainText('active')
  })
})
