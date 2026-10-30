import { expect, test, type Page } from '@playwright/test'
import { MockBackend, addDays, branchInstant, branchToday, ids, patientIds, practitionerIds, signIn, todayIn } from './mock-backend'
import { completeRegistration } from '../registration'

/**
 * Sprint 2 UI against the mocked API (SPRINT2-CONTRACT.md API v2 + CTO answers 2026-10-09):
 * patient detail/edit/soft delete/restore, phone + DOB search, duplicate warning, branch-zone DOB
 * checks, staff schedules, branch calendar with booking and conflicts, reception check-in and the
 * OPD queue board. Patient names come from the embedded summary; `legacyApi` covers the fallbacks.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

/** GET /patients/{id} calls — API v2 rows carry a patient summary, so screens should not make these. */
const perPatientFetches = () => backend.calls.filter((c) => c.method === 'GET' && /^\/api\/v1\/patients\/[0-9a-f-]{36}$/.test(c.path))

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })

test.describe('2.1 patients', () => {
  test('search by phone + DOB (in the body), open, edit and save a patient', async ({ page }) => {
    await signIn(page, 'admin@alpha.example')
    await nav(page, 'Patients').click()
    await page.getByLabel('Phone').fill('98450 00002')
    await page.getByLabel('Date of birth').fill('1985-05-05')
    await expect(page.getByTestId('patient-row')).toHaveCount(1)
    const search = backend.calls.filter((c) => c.path === '/api/v1/patients/search').at(-1)!
    expect(search).toMatchObject({ method: 'POST', body: { phone: '98450 00002', dateOfBirth: '1985-05-05' } })
    expect(backend.calls.filter((c) => /98450|1985-05-05/.test(c.url))).toEqual([])

    await page.getByRole('link', { name: 'Synthetic-Alpha, Ravi' }).click()
    await expect(page.getByRole('heading', { name: /Synthetic-Alpha, Ravi/ })).toBeVisible()
    await page.getByRole('button', { name: 'Edit patient' }).click()
    const form = page.getByRole('form', { name: 'Edit patient' })
    await form.getByLabel('Email (optional)').fill('ravi@synthetic.example')
    await form.getByRole('button', { name: 'Save changes' }).click()
    await expect(page.getByText('Changes saved.')).toBeVisible()
    await expect(page.getByTestId('patient-details')).toContainText('ravi@synthetic.example')
    const patch = backend.calls.find((c) => c.method === 'PATCH')!
    expect(patch.path).toBe(`/api/v1/patients/${patientIds.ravi}`)
    expect(patch.body).not.toHaveProperty('mrn')
  })

  test('soft delete with confirmation hides the patient; an admin can list deleted and restore', async ({ page }) => {
    await signIn(page, 'admin@alpha.example')
    await page.goto(`/patients/${patientIds.ravi}`)
    await page.getByRole('button', { name: 'Delete patient' }).click()
    const dialog = page.getByRole('alertdialog', { name: 'Delete this patient?' })
    await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeFocused()
    await dialog.getByLabel('Reason (optional)').fill('Registered twice')
    await dialog.getByRole('button', { name: 'Delete patient' }).click()

    await expect(page.getByText('Patient ALP-0002 deleted.')).toBeVisible()
    await expect(page.getByTestId('patient-row')).toHaveCount(1)
    expect(backend.calls.find((c) => c.method === 'DELETE')!.body).toEqual({ reason: 'Registered twice' })

    await page.goto(`/patients/${patientIds.ravi}`)
    await expect(page.getByTestId('patient-not-found')).toBeVisible()

    await nav(page, 'Patients').click()
    await page.getByLabel('Include deleted patients').check()
    await expect(page.getByTestId('patient-deleted-badge')).toHaveCount(1)
    await page.getByRole('button', { name: 'Restore ALP-0002' }).click()
    await expect(page.getByTestId('patient-deleted-badge')).toHaveCount(0)
    await page.getByLabel('Include deleted patients').uncheck()
    await expect(page.getByTestId('patient-row')).toHaveCount(2)
  })

  test('deleting a patient with an open appointment explains the 409 (receptionist at the branch)', async ({ page }) => {
    await signIn(page, 'reception@alpha.example')
    await page.goto(`/patients/${patientIds.asha}`)
    await page.getByRole('button', { name: 'Delete patient' }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Delete patient' }).click()
    await expect(page.getByRole('alert')).toContainText('open appointments')
    await expect(page.getByRole('heading', { name: /Synthetic-Alpha, Asha/ })).toBeVisible()
  })

  test('duplicate warning on register: a shared name needs a reason, a shared phone does not continue', async ({ page }) => {
    await signIn(page, 'reception@alpha.example')
    await page.goto('/patients/new')
    await page.getByLabel('First name').fill('Ravi')
    await page.getByLabel('Last name').fill('Synthetic-Alpha')
    await completeRegistration(page)
    await page.getByRole('button', { name: 'Register patient' }).click()

    const warning = page.getByTestId('duplicate-warning')
    await expect(warning).toContainText('ALP-0002')
    await expect(warning).toContainText('same name')
    expect(backend.calls.some((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toBe(false)
    await expect(warning.getByRole('link', { name: 'Open existing record ALP-0002' })).toHaveAttribute('href', `/patients/${patientIds.ravi}`)
    await warning.getByLabel('Why this is a different person').fill('Different person, confirmed at the desk')
    await warning.getByRole('button', { name: 'Register anyway' }).click()
    await expect(page.getByText('Patient ALPHA-000001 registered.')).toBeVisible()
    expect(backend.calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({
      duplicateOverrideReason: 'Different person, confirmed at the desk',
    })
  })

  test.describe('workstation and branch in different time zones', () => {
    // Workstation at UTC-11, Alpha Main at UTC+14: the branch is always at least a day ahead.
    test.use({ timezoneId: 'Pacific/Pago_Pago' })

    test('DOB "today" is the branch\'s date: a newborn born today at the branch registers', async ({ page }) => {
      backend.branchTimeZones.set(ids.alphaMain, 'Pacific/Kiritimati')
      const branchDay = todayIn('Pacific/Kiritimati')
      expect(branchDay > todayIn('Pacific/Pago_Pago')).toBe(true)
      await signIn(page, 'reception@alpha.example')
      await page.goto('/patients/new')
      const dob = page.getByLabel('Date of birth')
      await expect(dob).toHaveAttribute('max', branchDay)

      await page.getByLabel('First name').fill('Baby')
      await page.getByLabel('Last name').fill('Synthetic-Alpha')
      // Tomorrow at the branch is rejected client-side (the API would 400 too)
      await dob.fill(addDays(branchDay, 1))
      await completeRegistration(page)
      await page.getByRole('button', { name: 'Register patient' }).click()
      await expect(page.getByText('Date of birth must be between 1900-01-01 and today')).toBeVisible()
      expect(backend.calls.some((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toBe(false)

      await dob.fill(branchDay)
      await completeRegistration(page)
      await page.getByRole('button', { name: 'Register patient' }).click()
      await expect(page.getByText('Patient ALPHA-000001 registered.')).toBeVisible()
      expect(backend.calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({ dateOfBirth: branchDay, registeredBranchId: ids.alphaMain })
    })
  })
})

test.describe('2.2 schedules and appointments', () => {
  test('staff schedule shows weekly hours per branch', async ({ page }) => {
    await signIn(page, 'doctor@alpha.example')
    await nav(page, 'Schedules').click()
    await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
    const row = page.getByTestId('schedule-row')
    await expect(row).toHaveCount(1)
    await expect(row.getByRole('rowheader')).toContainText('Dr. Rao (synthetic)')
    await expect(row.getByTestId('schedule-cell').first()).toContainText('09:00–13:00')
    await page.getByLabel('Showing branch').selectOption(ids.alphaEast)
    await expect(page.getByTestId('schedule-row').getByRole('rowheader')).toContainText('Dr. Iyer (synthetic)')
    await expect(page.getByTestId('calendar-range')).toContainText('Asia/Kolkata')
  })

  test('day and week views; book a slot; a conflicting booking is reported and the slot list refreshes', async ({ page }) => {
    await signIn(page, 'reception@alpha.example')
    await nav(page, 'Appointments').click()
    // Branch-bound receptionist: only Alpha Main
    await expect(page.getByLabel('Showing branch')).toHaveValue(ids.alphaMain)
    const todayAppt = page.getByTestId('appointment')
    await expect(todayAppt).toHaveCount(1)
    await expect(todayAppt).toContainText('09:30–09:45')
    await expect(todayAppt).toContainText('Synthetic-Alpha, Asha')

    await page.getByRole('button', { name: 'Week', exact: true }).click()
    await expect(page.getByTestId('calendar-day')).toHaveCount(7)
    await page.getByRole('button', { name: 'Day', exact: true }).click()

    const tomorrow = addDays(branchToday(), 1)
    await page.getByRole('button', { name: 'Book appointment' }).click()
    const form = page.getByRole('form', { name: 'Book appointment' })
    // GET /practitioners?branchId= (API v2): only Dr. Rao works at Alpha Main
    await expect(form.getByLabel('Practitioner').getByRole('option')).toHaveText(['Select a practitioner…', 'Dr. Rao (synthetic) (General medicine)'])
    expect(backend.calls.some((c) => c.path === '/api/v1/practitioners' && new URL(c.url).searchParams.get('branchId') === ids.alphaMain)).toBe(true)
    await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
    await form.getByLabel('Appointment date').fill(tomorrow)
    await form.getByLabel('Find patient').fill('Ravi')
    await form.getByRole('option', { name: /Synthetic-Alpha, Ravi/ }).click()

    // Conflict: another desk takes 09:15 between picking and confirming.
    await form.getByText('09:15', { exact: true }).click()
    backend.bookDirectly({ branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.asha, startsAt: branchInstant(tomorrow, '09:15'), endsAt: branchInstant(tomorrow, '09:30') })
    await form.getByRole('button', { name: 'Confirm booking' }).click()
    await expect(form.getByRole('alert')).toContainText('That slot was just booked for this practitioner')
    await expect(form.getByText('09:15', { exact: true })).toHaveCount(0)

    await form.getByText('09:00', { exact: true }).click()
    await form.getByRole('button', { name: 'Confirm booking' }).click()
    await expect(page.getByText(/Booked Ravi Synthetic-Alpha with Dr\. Rao \(synthetic\) on .* at 09:00\./)).toBeVisible()
    await expect(page.getByLabel('Date', { exact: true })).toHaveValue(tomorrow)
    await expect(page.getByTestId('appointment').filter({ hasText: 'Synthetic-Alpha, Ravi' })).toContainText('09:00–09:15')
    const post = backend.calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/appointments').at(-1)!
    expect(post.body).toEqual({ branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.ravi, startsAt: branchInstant(tomorrow, '09:00'), endsAt: branchInstant(tomorrow, '09:15') })
    // names came from the embedded patient summary
    expect(perPatientFetches()).toEqual([])
  })

  test('older API (no patient summary, ?branchId= → 400): names and practitioner list still work', async ({ page }) => {
    backend.legacyApi = true
    await signIn(page, 'reception@alpha.example')
    await nav(page, 'Appointments').click()
    await expect(page.getByTestId('appointment')).toContainText('Synthetic-Alpha, Asha')
    expect(perPatientFetches().map((c) => c.path)).toEqual([`/api/v1/patients/${patientIds.asha}`])

    await page.getByRole('button', { name: 'Book appointment' }).click()
    const form = page.getByRole('form', { name: 'Book appointment' })
    // schedule-based fallback: still only Dr. Rao at Alpha Main
    await expect(form.getByLabel('Practitioner').getByRole('option')).toHaveText(['Select a practitioner…', 'Dr. Rao (synthetic) (General medicine)'])
    expect(backend.calls.some((c) => c.path === '/api/v1/practitioners' && c.url.includes('branchId='))).toBe(true)
    expect(backend.calls.some((c) => c.path === '/api/v1/schedules' && new URL(c.url).searchParams.get('branchId') === ids.alphaMain)).toBe(true)
  })
})

test.describe('2.3 check-in and OPD queue', () => {
  test('reception checks in an appointment and a walk-in; tokens are issued per branch-day', async ({ page }) => {
    await signIn(page, 'reception@alpha.example')
    await nav(page, 'Check-in').click()
    await page.getByRole('button', { name: 'Check in Asha Synthetic-Alpha at 09:30' }).click()
    await expect(page.getByTestId('token-number')).toHaveText('1')
    await expect(page.getByTestId('checkin-appointment')).toContainText('Checked in')

    const walkIn = page.getByRole('form', { name: 'Walk-in check-in' })
    await walkIn.getByLabel('Find walk-in patient').fill('ALP-0002')
    await walkIn.getByRole('option', { name: /Synthetic-Alpha, Ravi/ }).click()
    await walkIn.getByRole('button', { name: 'Issue walk-in token' }).click()
    await expect(page.getByTestId('token-number')).toHaveText('2')

    // Same walk-in again while still waiting → 409 already_checked_in
    await walkIn.getByLabel('Find walk-in patient').fill('ALP-0002')
    await walkIn.getByRole('option', { name: /Synthetic-Alpha, Ravi/ }).click()
    await walkIn.getByRole('button', { name: 'Issue walk-in token' }).click()
    await expect(page.getByRole('alert')).toContainText('already waiting or in consultation')
    expect(perPatientFetches()).toEqual([])
  })

  test('queue board polls for new tokens; doctor calls in and finishes, cannot remove', async ({ page }) => {
    backend.issueToken(ids.alphaMain, patientIds.asha, practitionerIds.rao)
    await page.clock.install()
    await signIn(page, 'doctor@alpha.example')
    await page.goto(`/queue?branch=${ids.alphaMain}`)
    await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
    const waiting = page.getByTestId('queue-waiting')
    await expect(waiting.getByTestId('queue-entry')).toHaveCount(1)
    await expect(waiting).toContainText('Synthetic-Alpha, Asha')

    backend.issueToken(ids.alphaMain, patientIds.ravi)
    await page.clock.fastForward('00:11') // > QUEUE_REFRESH_MS
    await expect(waiting.getByTestId('queue-entry')).toHaveCount(2)
    await expect(waiting.locator('[data-token="2"]')).toContainText('walk-in')

    await expect(page.getByRole('button', { name: 'Remove token 1' })).toHaveCount(0)
    await page.getByRole('button', { name: 'Call in token 1' }).click()
    await expect(page.getByTestId('queue-in_consultation').getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
    await page.getByRole('button', { name: 'Mark done token 1' }).click()
    await expect(page.getByTestId('queue-done').getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
    expect(backend.calls.filter((c) => c.method === 'PATCH').map((c) => c.body)).toEqual([{ status: 'in_consultation' }, { status: 'done' }])
    expect(perPatientFetches()).toEqual([])
  })

  test('role-aware navigation: billing reads the calendar and the OPD queue with Collect (#182), and cannot check in or close the day', async ({ page }) => {
    backend.issueToken(ids.alphaMain, patientIds.asha, practitionerIds.rao)
    await signIn(page, 'billing@alpha.example')
    await expect(nav(page, 'Appointments')).toBeVisible()
    await expect(nav(page, 'OPD queue')).toBeVisible()
    await expect(nav(page, 'Schedules')).toBeVisible()
    await expect(nav(page, 'Check-in')).toHaveCount(0)
    await page.goto(`/queue?branch=${ids.alphaMain}`)
    await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
    await expect(page.getByTestId('queue-waiting').getByTestId('queue-entry')).toHaveCount(1)
    await expect(page.getByRole('button', { name: /^Collect for token / }).first()).toBeVisible()
    await expect(page.getByTestId('queue-close-day-button')).toHaveCount(0)
    await expect(page.getByRole('button', { name: /^Call in token / })).toHaveCount(0)
    await page.goto('/reception/check-in')
    await expect(page.getByTestId('forbidden')).toBeVisible()
    await page.goto(`/appointments?branch=${ids.alphaMain}`)
    await expect(page.getByTestId('appointment')).toHaveCount(1)
    await expect(page.getByRole('button', { name: 'Book appointment' })).toHaveCount(0)
  })
})
