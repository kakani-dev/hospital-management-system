import { expect, test, type Locator, type Page } from '@playwright/test'
import { ADD_MEMBER_GENERIC_MESSAGE, MockBackend, OPERATOR_EMAIL, PASSWORD, addDays, branchInstant, branchToday, ids, patientIds, practitionerIds, signIn } from './mock-backend'

/**
 * The four workspace flows stay on one route and inside the click targets in docs/ux-flows.md.
 * A click is a pointer activation of a button, link, select or result. Typing into a text,
 * email, search, tel or date field is not a click.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

async function armClicks(page: Page) {
  await page.evaluate(() => {
    const w = window as unknown as { __clicks?: number }
    w.__clicks = 0
    document.addEventListener(
      'click',
      (event) => {
        const target = event.target
        if (target instanceof HTMLInputElement && /^(text|email|search|tel|date|password|number)$/.test(target.type)) return
        if (target instanceof HTMLTextAreaElement) return
        w.__clicks = (w.__clicks ?? 0) + 1
      },
      true,
    )
  })
}

async function clicks(page: Page) {
  return page.evaluate(() => (window as unknown as { __clicks?: number }).__clicks ?? 0)
}

/** Today's free slots may already have passed; tomorrow's first slot is then preselected. */
async function ensureNextSlot(form: Locator) {
  const none = form.getByTestId('no-free-slots')
  const checked = form.locator('input[type="radio"]:checked')
  await expect.poll(async () => (await none.count()) + (await checked.count())).toBeGreaterThan(0)
  if ((await none.count()) > 0) {
    await form.getByLabel('Appointment date').fill(addDays(branchToday(), 1))
  }
  await expect(checked).toHaveCount(1)
}

test('reception books and checks in from the patient panel without leaving the calendar', async ({ page }) => {
  backend.appointments.push({
    id: 'a0000000-0000-4000-8000-0000000000e1',
    tenantId: ids.alpha,
    branchId: ids.alphaEast,
    practitionerId: practitionerIds.iyer,
    patientId: patientIds.asha,
    startsAt: branchInstant(addDays(branchToday(), -3), '14:00'),
    endsAt: branchInstant(addDays(branchToday(), -3), '14:20'),
    status: 'completed',
    reason: null,
    cancelReason: null,
  })
  await signIn(page, 'reception@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await expect(page.getByRole('heading', { name: 'Appointments' })).toBeVisible()
  await armClicks(page)
  const path = new URL(page.url()).pathname

  await page.keyboard.press('Control+k')
  await page.getByTestId('command-palette-input').fill('Asha')
  await page.getByTestId('command-patient').filter({ hasText: 'Synthetic-Alpha, Asha' }).click()

  const panel = page.getByTestId('patient-context')
  await expect(panel).toBeVisible()
  await expect(panel.getByText('ALP-0001')).toBeVisible()
  const visits = panel.getByTestId('visit-row')
  await expect(visits).toHaveCount(2)
  // A branch-scoped receptionist cannot see East's name; the visit is still marked as another branch.
  await expect(visits.filter({ hasText: 'Other branch' })).toHaveCount(1)
  await expect(visits.filter({ hasText: 'Alpha Main Campus' })).not.toContainText('Other branch')

  await panel.getByTestId('context-book').click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  await ensureNextSlot(form)
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  await expect(panel.getByText(/Booked Asha Synthetic-Alpha/)).toBeVisible()
  await panel.getByRole('button', { name: /Check in Asha Synthetic-Alpha at 09:30/ }).click()
  await expect(panel.getByTestId('token-number')).toBeVisible()

  expect(new URL(page.url()).pathname).toBe(path)
  expect(await clicks(page)).toBeLessThanOrEqual(6)
})

test('a new patient typed in the booking drawer warns about a duplicate on this page', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Find patient').fill('9845000001')
  await form.getByRole('option', { name: /add new patient/i }).click()
  await expect(page.getByTestId('quick-register')).toBeVisible()
  await expect(page.getByTestId('duplicate-warning')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Save patient' })).toBeVisible()
  expect(new URL(page.url()).pathname).toBe('/appointments')
})

test('a doctor reads history and books a follow-up without leaving the queue', async ({ page }) => {
  const doctor = backend.users.get('doctor@alpha.example')!
  backend.practitioners.find((p) => p.id === practitionerIds.rao)!.userId = doctor.id
  backend.issueToken(ids.alphaMain, patientIds.asha, practitionerIds.rao)
  await signIn(page, 'doctor@alpha.example')
  await page.goto(`/queue?branch=${ids.alphaMain}`)
  await expect(page.getByRole('heading', { name: 'OPD queue' })).toBeVisible()
  await armClicks(page)

  await page.getByTestId('open-patient-context').click()
  await expect(page.getByTestId('visit-history')).toBeVisible()
  await expect(page.getByTestId('visit-row').first()).toBeVisible()
  await page.getByTestId('context-follow-up').click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await expect(form.getByLabel('Practitioner')).toHaveValue(practitionerIds.rao)
  await ensureNextSlot(form)
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  await expect(page.getByText(/Booked Asha Synthetic-Alpha/)).toBeVisible()

  expect(new URL(page.url()).pathname).toBe('/queue')
  expect(await clicks(page)).toBeLessThanOrEqual(4)
})

test('a tenant admin invites staff and adds a branch on the hospital desk', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/admin/desk')
  await expect(page.getByRole('heading', { name: 'Hospital desk' })).toBeVisible()
  await armClicks(page)

  const members = page.getByRole('form', { name: 'Add member' })
  await members.getByLabel('Email').fill('north.desk@alpha.example')
  await members.getByRole('button', { name: 'Add member' }).click()
  await expect(page.getByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeVisible()

  const branches = page.getByRole('form', { name: 'Add branch' })
  await branches.getByLabel('Code').fill('north')
  await branches.getByLabel('Branch name').fill('North Wing')
  await branches.getByRole('button', { name: 'Add branch' }).click()
  await expect(page.getByText('Branch North Wing created.')).toBeVisible()

  expect(new URL(page.url()).pathname).toBe('/admin/desk')
  expect(await clicks(page)).toBeLessThanOrEqual(4)
})

test('a platform operator creates a hospital from search and stays on the console', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email').fill(OPERATOR_EMAIL)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: 'Hospitals' })).toBeVisible()
  await armClicks(page)

  await page.keyboard.press('Control+k')
  await page.getByTestId('command-palette-input').fill('Create')
  await page.getByTestId('command-action').filter({ hasText: 'Create hospital' }).click()
  const form = page.getByTestId('create-tenant-drawer').getByRole('form', { name: 'Create hospital' })
  await form.getByLabel('Hospital name').fill('Synthetic North Hospital')
  await expect(form.getByLabel('Hospital code')).not.toHaveValue('')
  await form.getByLabel('First admin email').fill('north.admin@synthetic.example')
  await form.getByRole('button', { name: 'Create hospital' }).click()
  await expect(page.getByTestId('invite-link-url')).toBeVisible()

  expect(new URL(page.url()).pathname).toBe('/platform')
  expect(await clicks(page)).toBeLessThanOrEqual(4)
})
