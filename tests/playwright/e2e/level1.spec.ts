import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { PASSWORD, bearer, createSyntheticUser, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * Level 1 through the edge with the real identity/scheduling services and Postgres RLS:
 * public hospital registration -> operator approval -> first-admin invite link claimed by the
 * contact; platform console 403 for staff; the operator cannot read patients or enter a hospital;
 * suspension blocks the hospital's staff and reactivation restores them; tenant-admin invite links
 * are tenant-scoped; branch delete/restore; calendar cancel with a reason and the status filter.
 *
 * The operator is the synthetic local/CI-only seed user (supabase/scripts/local-platform-operator-seed.sql).
 */
const OPERATOR = 'operator@medicore.example'

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })

async function signInTo(page: Page, email: string, heading: string) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible()
}

async function approveAsOperator(request: APIRequestContext, contactEmail: string, code: string) {
  const op = bearer(await tokenFor(request, OPERATOR))
  const pending = (await (await request.get('/api/v1/platform/hospital-requests?status=pending', { headers: op })).json()) as { id: string; contactEmail: string }[]
  const mine = pending.find((r) => r.contactEmail === contactEmail)
  expect(mine, `pending request for ${contactEmail}`).toBeTruthy()
  const approved = await request.post(`/api/v1/platform/hospital-requests/${mine!.id}/approve`, { headers: op, data: { tenantCode: code } })
  expect(approved.status()).toBe(200)
  return (await approved.json()) as { tenantId: string; invite: { token: string; path: string } }
}

test.describe('Level 1: onboarding and the platform console', () => {
  test('register -> operator approves in the console -> the contact claims the admin invite and runs the new hospital', async ({ page, browser }) => {
    const contact = await createSyntheticUser('l1contact')
    const name = `Synthetic ${unique('Lotus')}`.slice(0, 40)

    // 1. Public registration (no session).
    await page.goto('/register-hospital')
    await page.getByLabel('Hospital name').fill(name)
    await page.getByLabel('Hospital time zone').fill('Asia/Dubai')
    await page.getByLabel('City').fill('Dubai')
    await page.getByLabel('Your name').fill('Contact Synthetic')
    await page.getByLabel('Work email').fill(contact)
    await page.getByLabel('Phone').fill('+971 4 555 0101')
    const sent = page.waitForResponse((r) => r.url().endsWith('/api/v1/public/hospital-signups'))
    await page.getByRole('button', { name: 'Send request' }).click()
    expect((await sent).status()).toBe(202)
    await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()

    // 2. The operator approves it in the console (lands on /platform: no hospital membership).
    await signInTo(page, OPERATOR, 'Hospitals')
    await expect(page).toHaveURL(/\/platform$/)
    await nav(page, 'Hospital requests').click()
    await page.getByRole('button', { name: `Approve ${name}` }).click()
    const code = unique('l1').toLowerCase()
    await page.getByRole('alertdialog').getByLabel('Hospital code').fill(code)
    await page.getByRole('alertdialog').getByRole('button', { name: 'Approve and create' }).click()
    const link = new URL(await page.getByTestId('invite-link-url').inputValue()).pathname
    expect(link).toMatch(/^\/invite\/[0-9a-f]{64}$/)

    // The hospital exists with the requested zone and one branch, no users yet.
    await page.goto('/platform')
    await page.getByLabel('Search hospitals').fill(code)
    const row = page.getByTestId('platform-tenant-row')
    await expect(row).toHaveCount(1)
    await expect(row).toContainText('Asia/Dubai')
    await row.getByRole('link', { name }).click()
    await expect(page.getByTestId('platform-tenant-details')).toContainText('Branches1')
    await expect(page.getByTestId('platform-tenant-details')).toContainText('Users0')

    // 3. The contact (fresh browser) previews, signs in with the invited email and joins.
    const ctx = await browser.newContext()
    const tab = await ctx.newPage()
    await tab.goto(link)
    await expect(tab.getByTestId('invite-preview')).toContainText(name)
    await tab.getByRole('button', { name: 'Sign in to accept' }).click()
    await tab.getByLabel('Email').fill(contact)
    await tab.getByLabel('Password').fill(PASSWORD)
    await tab.getByRole('button', { name: 'Sign in' }).click()
    await tab.getByRole('button', { name: `Join ${name}` }).click()
    await expect(tab.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
    await expect(tab.getByTestId('tenant-name')).toContainText(name)
    await nav(tab, 'Branches').click()
    await expect(tab.getByTestId('branch-row')).toHaveCount(1)
    await expect(tab.getByTestId('branch-row')).toContainText('Asia/Dubai (hospital zone)')
    // single use
    await tab.goto(link)
    await expect(tab.getByText(/not valid any more/)).toBeVisible()
    await ctx.close()
  })

  test('the console is 403 for staff; the operator cannot read patients or enter a hospital', async ({ page, request }) => {
    const staff = bearer(await tokenFor(request, users.alphaAdmin))
    for (const path of ['/api/v1/platform/tenants', '/api/v1/platform/hospital-requests']) {
      expect((await request.get(path, { headers: staff })).status(), path).toBe(403)
    }
    expect((await request.post('/api/v1/platform/tenants', { headers: staff, data: { code: unique('x').toLowerCase(), name: 'Nope', timeZone: 'UTC', adminEmail: 'n@x.example' } })).status()).toBe(403)

    const op = bearer(await tokenFor(request, OPERATOR))
    expect((await request.get('/api/v1/patients', { headers: op })).status()).toBe(403)
    expect((await request.get(`/api/v1/patients/${ids.alphaPatient}`, { headers: op })).status()).toBe(403)
    expect((await request.get(`/api/v1/appointments?branchId=${ids.alphaMain}`, { headers: op })).status()).toBe(403)
    expect((await request.post('/api/v1/me/context', { headers: op, data: { tenantId: ids.alpha } })).status()).toBe(403)
    const me = (await (await request.get('/api/v1/me', { headers: op })).json()) as { activeTenantId: string | null; isPlatformAdmin: boolean; memberships: unknown[] }
    expect(me).toMatchObject({ activeTenantId: null, isPlatformAdmin: true, memberships: [] })

    await signIn(page, users.alphaAdmin)
    await page.goto('/platform')
    await expect(page.getByText('Only platform operators can open the platform console.')).toBeVisible()
  })

  test('suspending a hospital blocks its staff; reactivating restores them', async ({ page, request }) => {
    const contact = await createSyntheticUser('l1susp')
    const sent = await request.post('/api/v1/public/hospital-signups', {
      data: { hospitalName: `Synthetic ${unique('Susp')}`.slice(0, 40), timeZone: 'Asia/Kolkata', contactName: 'Susp Synthetic', contactEmail: contact, phone: '+91 20 5550 2222', city: 'Pune' },
    })
    expect(sent.status()).toBe(202)
    const code = unique('susp').toLowerCase()
    const { tenantId, invite } = await approveAsOperator(request, contact, code)
    const staff = bearer(await tokenFor(request, contact))
    expect((await request.post('/api/v1/me/invite-links/claim', { headers: staff, data: { token: invite.token } })).status()).toBe(200)
    expect((await request.get('/api/v1/branches', { headers: bearer(await tokenFor(request, contact)) })).status()).toBe(200)

    await signInTo(page, OPERATOR, 'Hospitals')
    await page.goto(`/platform/hospitals/${tenantId}`)
    await page.getByRole('button', { name: 'Suspend hospital' }).click()
    await page.getByRole('alertdialog').getByLabel('Reason').fill('Synthetic compliance hold')
    await page.getByRole('alertdialog').getByRole('button', { name: 'Suspend' }).click()
    await expect(page.getByTestId('platform-tenant-status')).toHaveText('suspended')

    // Blocked at grant: a fresh token resolves no tenant, tenant APIs answer 403.
    const blocked = bearer(await tokenFor(request, contact))
    expect((await request.get('/api/v1/branches', { headers: blocked })).status()).toBe(403)
    expect((await request.post('/api/v1/me/context', { headers: blocked, data: { tenantId } })).status()).toBe(403)
    expect(((await (await request.get('/api/v1/me', { headers: blocked })).json()) as { activeTenantId: string | null }).activeTenantId).toBeNull()

    await page.getByRole('button', { name: 'Reactivate hospital' }).click()
    await page.getByRole('alertdialog').getByLabel('Reason').fill('Hold lifted')
    await page.getByRole('alertdialog').getByRole('button', { name: 'Reactivate' }).click()
    await expect(page.getByTestId('platform-tenant-status')).toHaveText('active')
    await expect(page.getByTestId('platform-tenant-history')).toContainText('Synthetic compliance hold')
    expect((await request.get('/api/v1/branches', { headers: bearer(await tokenFor(request, contact)) })).status()).toBe(200)
  })

  test('tenant-admin invite links are scoped to the hospital (cross-tenant revoke is 404)', async ({ page, request }) => {
    const invitee = await createSyntheticUser('l1link')
    await signIn(page, users.alphaAdmin)
    await nav(page, 'Members').click()
    const form = page.getByRole('form', { name: 'Create invite link' })
    await form.getByLabel('Email').fill(invitee)
    await form.getByLabel('Role').selectOption('receptionist')
    await form.getByLabel('Branch scope').selectOption({ label: 'Alpha East Clinic' })
    await form.getByRole('button', { name: 'Create invite link' }).click()
    const token = new URL(await page.getByTestId('invite-link-url').inputValue()).pathname.split('/').pop()!

    const alphaLinks = (await (await request.get('/api/v1/members/invite-links', { headers: bearer(await tokenFor(request, users.alphaAdmin)) })).json()) as { id: string; email: string }[]
    const mine = alphaLinks.find((l) => l.email === invitee)!
    const beta = bearer(await tokenFor(request, users.betaAdmin))
    expect((await request.delete(`/api/v1/members/invite-links/${mine.id}`, { headers: beta })).status()).toBe(404)
    expect(((await (await request.get('/api/v1/members/invite-links', { headers: beta })).json()) as { email: string }[]).some((l) => l.email === invitee)).toBe(false)
    // Someone else cannot claim it; the invitee can, into Alpha East only.
    expect((await request.post('/api/v1/me/invite-links/claim', { headers: bearer(await tokenFor(request, users.outsider)), data: { token } })).status()).toBe(403)
    const claimed = await request.post('/api/v1/me/invite-links/claim', { headers: bearer(await tokenFor(request, invitee)), data: { token } })
    expect(claimed.status()).toBe(200)
    expect(await claimed.json()).toMatchObject({ tenantId: ids.alpha, role: 'receptionist', branchId: ids.alphaEast })
    const me = (await (await request.get('/api/v1/me', { headers: bearer(await tokenFor(request, invitee)) })).json()) as { accessibleBranches: { id: string }[] }
    expect(me.accessibleBranches.map((b) => b.id)).toEqual([ids.alphaEast])
  })
})

test.describe('Level 1: branches and appointments', () => {
  test('admin deletes and restores a branch', async ({ page, request }) => {
    const admin = bearer(await tokenFor(request, users.alphaAdmin))
    const code = unique('br').toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 20)
    const name = `Zz Branch ${code}`
    expect((await request.post('/api/v1/branches', { headers: admin, data: { code, name } })).status()).toBe(201)
    await signIn(page, users.alphaAdmin)
    await nav(page, 'Branches').click()
    await page.getByRole('button', { name: `Delete ${name}` }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Delete branch' }).click()
    await expect(page.getByText(`${name} was deleted.`, { exact: false })).toBeVisible()
    await expect(page.getByRole('button', { name: `Delete ${name}` })).toHaveCount(0)
    await page.getByLabel('Show deleted branches').check()
    await page.getByRole('button', { name: `Restore ${name}` }).click()
    await expect(page.getByText(`${name} was restored`, { exact: false })).toBeVisible()
    await page.getByLabel('Show deleted branches').uncheck()
    await expect(page.getByRole('button', { name: `Delete ${name}` })).toBeVisible()
  })

  test('reception cancels with a reason; the status filter and patient search narrow the calendar', async ({ page, request }) => {
    const admin = bearer(await tokenFor(request, users.alphaAdmin))
    const reception = bearer(await tokenFor(request, users.alphaReception))
    const practitioner = (await (await request.post('/api/v1/practitioners', { headers: admin, data: { displayName: `Dr ${unique('L1')} (synthetic)` } })).json()) as { id: string }
    // A day a week ahead (same weekday), so the slot is in the future in any zone.
    const day = new Date(Date.now() + 7 * 86_400_000)
    const date = day.toISOString().slice(0, 10)
    const weekday = ((day.getUTCDay() + 6) % 7) + 1
    expect((await request.post('/api/v1/schedules', { headers: admin, data: { practitionerId: practitioner.id, branchId: ids.alphaMain, weekday, startTime: '08:00', endTime: '20:00', slotMinutes: 15, validFrom: date, validTo: date } })).status()).toBe(201)
    const lastName = `Zz-L1-${unique('C')}`
    const patient = (await (await request.post('/api/v1/patients', { headers: reception, data: { firstName: 'Cancel', lastName, registeredBranchId: ids.alphaMain, sex: 'female' } })).json()) as { id: string }
    const slots = (await (await request.get(`/api/v1/slots?branchId=${ids.alphaMain}&from=${date}&to=${date}&practitionerId=${practitioner.id}`, { headers: reception })).json()) as { startsAt: string; endsAt: string }[]
    expect(slots.length).toBeGreaterThan(0)
    const booked = await request.post('/api/v1/appointments', { headers: reception, data: { branchId: ids.alphaMain, practitionerId: practitioner.id, patientId: patient.id, startsAt: slots[0]!.startsAt, endsAt: slots[0]!.endsAt, reason: 'Synthetic follow-up' } })
    expect(booked.status()).toBe(201)
    const appointment = (await booked.json()) as { id: string; startsAt: string }

    await signIn(page, users.alphaReception)
    await page.goto(`/appointments?branch=${ids.alphaMain}&date=${date}`)
    await page.getByLabel('Practitioner').selectOption(practitioner.id)
    const item = page.getByTestId('appointment')
    await expect(item).toHaveCount(1)
    await expect(item).toContainText('Reason: Synthetic follow-up')
    await page.getByLabel('Find patient').fill('nobody-at-all')
    await expect(item).toHaveCount(0)
    await page.getByLabel('Find patient').fill(lastName)
    await expect(item).toHaveCount(1)
    await item.getByRole('button', { name: 'Cancel appointment' }).click()
    await page.getByRole('alertdialog').getByLabel('Reason (optional)').fill('Patient travelling (synthetic)')
    const cancelled = page.waitForResponse((r) => r.url().endsWith(`/api/v1/appointments/${appointment.id}/cancel`))
    await page.getByRole('alertdialog').getByRole('button', { name: 'Cancel appointment' }).click()
    expect((await cancelled).status()).toBe(200)
    await expect(item).toHaveAttribute('data-status', 'cancelled')
    await page.getByLabel('Status').selectOption('booked')
    await expect(item).toHaveCount(0)
    await page.getByLabel('Status').selectOption('cancelled')
    await expect(item).toHaveCount(1)
    const after = (await (await request.get(`/api/v1/appointments/${appointment.id}`, { headers: reception })).json()) as { status: string; cancelReason: string | null }
    expect(after).toMatchObject({ status: 'cancelled', cancelReason: 'Patient travelling (synthetic)' })
  })
})

test.describe('phone viewport (390×844)', () => {
  test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })

  test('the header keeps a compact hospital/branch summary; the selects live in the drawer', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    const header = page.locator('header.app-header')
    const compact = header.getByTestId('compact-context')
    await expect(compact).toBeVisible()
    await expect(header.getByRole('combobox')).toHaveCount(0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
    await compact.tap()
    const drawer = page.getByTestId('sidebar-context')
    await expect(drawer).toBeInViewport()
    await expect(drawer.getByRole('combobox', { name: 'Branch' })).toBeVisible()
  })
})
