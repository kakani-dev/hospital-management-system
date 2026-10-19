import { expect, test, type Page } from '@playwright/test'
import { MockBackend, addDays, branchInstant, branchToday, ids, patientIds, practitionerIds, signIn } from './mock-backend'

/**
 * Phase 2 screens against the mocked API: dashboard counts, reschedule / no-show on the calendar,
 * practitioner and working-hours admin, hospital time zone settings (409 future-bookings
 * confirmation) and editing a branch's zone override.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })

test('dashboard stat cards come from the API for the chosen branch', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
  await expect(page.getByTestId('stat-appointments')).toHaveText('1')
  await expect(page.getByTestId('stat-waiting')).toHaveText('0')
  await expect(page.getByTestId('stat-registered')).toHaveText('0')
  expect(backend.calls.some((c) => c.path === '/api/v1/patients/stats' && new URL(c.url).searchParams.get('branchId') === ids.alphaMain)).toBe(true)
})

test('reception reschedules a booked appointment and marks a missed one as no-show', async ({ page }) => {
  const yesterday = addDays(branchToday(), -1)
  backend.bookDirectly({ branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.ravi, startsAt: branchInstant(yesterday, '10:00'), endsAt: branchInstant(yesterday, '10:15') })
  await signIn(page, 'reception@alpha.example')
  await nav(page, 'Appointments').click()
  const tomorrow = addDays(branchToday(), 1)
  await page.getByTestId('appointment').filter({ hasText: 'Asha' }).getByRole('button', { name: 'Reschedule' }).click()
  const form = page.getByRole('form', { name: 'Reschedule appointment' })
  await form.getByLabel('New date').fill(tomorrow)
  await form.getByText('10:00', { exact: true }).click()
  await form.getByRole('button', { name: 'Confirm new time' }).click()
  await expect(page.getByText(/^Moved Asha Synthetic-Alpha to .* at 10:00\.$/)).toBeVisible()
  await expect(page.getByLabel('Date', { exact: true })).toHaveValue(tomorrow)
  await expect(page.getByTestId('appointment').filter({ hasText: 'Asha' })).toContainText('10:00–10:15')

  await page.getByLabel('Date', { exact: true }).fill(yesterday)
  const missed = page.getByTestId('appointment').filter({ hasText: 'Ravi' })
  await missed.getByRole('button', { name: 'Mark no-show' }).click()
  await page.getByRole('alertdialog').getByRole('button', { name: 'Mark no-show' }).click()
  await expect(page.getByText('Ravi Synthetic-Alpha was marked as a no-show.')).toBeVisible()
  await expect(missed).toHaveAttribute('data-status', 'no_show')
})

test('admin adds a practitioner with working hours, deletes and restores them', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await nav(page, 'Practitioners').click()
  await page.getByLabel('Display name').fill('Dr. Menon (synthetic)')
  await page.getByLabel('Specialty (optional)').fill('Cardiology')
  await page.getByRole('button', { name: 'Add practitioner' }).click()
  await expect(page.getByText('Dr. Menon (synthetic) added.', { exact: false })).toBeVisible()

  await nav(page, 'Working hours').click()
  await page.getByLabel('Showing branch').selectOption(ids.alphaEast)
  const add = page.getByRole('form', { name: 'Add working hours' })
  await add.getByLabel('Practitioner').selectOption({ label: 'Dr. Menon (synthetic)' })
  await add.getByLabel('Weekday').selectOption('2')
  await add.getByLabel('Start time').fill('14:00')
  await add.getByLabel('End time').fill('17:00')
  await add.getByRole('button', { name: 'Add hours' }).click()
  await expect(page.getByText('Added Dr. Menon (synthetic) on Tuesday 14:00–17:00.')).toBeVisible()
  // The same hours again overlap.
  await add.getByRole('button', { name: 'Add hours' }).click()
  await expect(page.getByText('These hours overlap another active schedule')).toBeVisible()

  await nav(page, 'Practitioners').click()
  await page.getByRole('button', { name: 'Delete Dr. Menon (synthetic)' }).click()
  await page.getByRole('alertdialog').getByRole('button', { name: 'Delete' }).click()
  await expect(page.getByText(/Dr\. Menon \(synthetic\) was deleted\./)).toBeVisible()
  await page.getByLabel('Show deleted').check()
  await page.getByRole('button', { name: 'Restore Dr. Menon (synthetic)' }).click()
  await expect(page.getByText('Dr. Menon (synthetic) was restored as inactive.', { exact: false })).toBeVisible()
  const row = page.getByTestId('practitioner-row').filter({ hasText: 'Dr. Menon' })
  await expect(row).toHaveAttribute('data-status', 'inactive')
  await page.getByRole('button', { name: 'Activate Dr. Menon (synthetic)' }).click()
  await expect(row).toHaveAttribute('data-status', 'active')
})

test('hospital time zone change asks to confirm future bookings', async ({ page }) => {
  const tomorrow = addDays(branchToday(), 1)
  backend.bookDirectly({ branchId: ids.alphaEast, practitionerId: practitionerIds.iyer, patientId: patientIds.ravi, startsAt: branchInstant(tomorrow, '14:00'), endsAt: branchInstant(tomorrow, '14:20') })
  await signIn(page, 'admin@alpha.example')
  await nav(page, 'Hospital settings').click()
  await expect(page.getByLabel('Hospital time zone')).toHaveValue('Asia/Kolkata')
  await page.getByLabel('Hospital time zone').fill('Asia/Dubai')
  await page.getByRole('button', { name: 'Save settings' }).click()
  const dialog = page.getByRole('alertdialog')
  await expect(dialog).toContainText('future booking')
  await dialog.getByRole('button', { name: 'Change time zone' }).click()
  await expect(page.getByText('Saved. The hospital time zone is now Asia/Dubai.')).toBeVisible()
  const patches = backend.calls.filter((c) => c.method === 'PATCH' && c.path === '/api/v1/tenants/current').map((c) => c.body)
  expect(patches).toEqual([{ timeZone: 'Asia/Dubai' }, { timeZone: 'Asia/Dubai', confirmFutureBookings: true }])
})

test('editing a branch sets and clears its own time zone', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await nav(page, 'Branches').click()
  const east = page.getByTestId('branch-row').filter({ hasText: 'Alpha East Clinic' })
  await expect(east).toContainText('Asia/Kolkata (hospital zone)')
  await east.getByRole('button', { name: 'Edit Alpha East Clinic' }).click()
  const drawer = page.getByTestId('branch-drawer')
  await drawer.getByLabel('Use hospital time zone (Asia/Kolkata)').uncheck()
  await drawer.getByLabel('Branch time zone').fill('Asia/Dubai')
  await drawer.getByRole('button', { name: 'Save branch' }).click()
  await expect(page.getByText('Alpha East Clinic saved.')).toBeVisible()
  await expect(east).toContainText('Asia/Dubai')
  await east.getByRole('button', { name: 'Use the hospital time zone at Alpha East Clinic' }).click()
  await expect(east).toContainText('Asia/Kolkata (hospital zone)')
})
