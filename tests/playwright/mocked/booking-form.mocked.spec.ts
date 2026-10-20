import { expect, test, type Page, type TestInfo } from '@playwright/test'
import { MockBackend, addDays, branchToday, ids, practitionerIds, signIn } from './mock-backend'

/**
 * Book appointment form (bug 20 Oct): with no practitioner bookable at the branch the picker was
 * silently empty, and Confirm said "Choose a practitioner, a free slot and a patient." even with a
 * patient chosen. Now: Confirm stays disabled, the hint names only what is missing, and empty
 * states explain why (admins get links to practitioner and working-hours setup).
 * BOOKING_SHOTS_DIR=<dir> also saves the screenshots there.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

async function shot(page: Page, info: TestInfo, name: string) {
  const dir = process.env.BOOKING_SHOTS_DIR
  const body = await page.screenshot({ ...(dir ? { path: `${dir}/${name}.png` } : {}) })
  await info.attach(name, { body, contentType: 'image/png' })
}

async function openBooking(page: Page) {
  await signIn(page, 'admin@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await page.getByRole('button', { name: 'Book appointment' }).click()
  return page.getByRole('form', { name: 'Book appointment' })
}

async function pickPatient(page: Page, form: ReturnType<Page['getByRole']>) {
  await form.getByLabel('Find patient').fill('Ravi')
  await form.getByRole('option', { name: /Synthetic-Alpha, Ravi/ }).click()
}

test('all schedules ended: explains the empty practitioner list and links admins to setup', async ({ page }, info) => {
  const yesterday = addDays(branchToday(), -1)
  for (const s of backend.schedules) s.validTo = yesterday
  const form = await openBooking(page)
  const empty = form.getByTestId('no-practitioners')
  await expect(empty).toContainText('No practitioner can be booked at this branch')
  await expect(empty.getByRole('link', { name: 'Set up practitioners' })).toHaveAttribute('href', '/admin/practitioners')
  await expect(empty.getByRole('link', { name: 'add working hours' })).toHaveAttribute('href', '/admin/working-hours')
  await expect(form.getByLabel('Practitioner')).toBeDisabled()
  await pickPatient(page, form)
  await expect(form.getByTestId('booking-missing')).toHaveText('Choose a practitioner and a free slot.')
  await expect(form.getByRole('button', { name: 'Confirm booking' })).toBeDisabled()
  await shot(page, info, 'booking-no-practitioners')
  await empty.getByRole('link', { name: 'add working hours' }).click()
  await expect(page).toHaveURL(/\/admin\/working-hours$/)
})

test('patient first: the hint names only the missing items; Confirm enables when complete', async ({ page }, info) => {
  const form = await openBooking(page)
  const confirm = form.getByRole('button', { name: 'Confirm booking' })
  await expect(confirm).toBeDisabled()
  await pickPatient(page, form)
  await expect(form.getByTestId('booking-missing')).toHaveText('Choose a practitioner and a free slot.')
  await shot(page, info, 'booking-missing-practitioner-slot')
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  await form.getByLabel('Appointment date').fill(addDays(branchToday(), 1))
  await expect(form.getByTestId('booking-missing')).toHaveText('Choose a free slot.')
  await form.getByText('09:00', { exact: true }).click()
  await expect(form.getByTestId('booking-missing')).toHaveCount(0)
  await expect(confirm).toBeEnabled()
  await shot(page, info, 'booking-ready')
})

test('no free slots on the date: says so and links admins to working hours', async ({ page }, info) => {
  const form = await openBooking(page)
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  // End Dr. Rao's schedules today, so tomorrow has no free slots.
  for (const s of backend.schedules) if (s.practitionerId === practitionerIds.rao) s.validTo = branchToday()
  await form.getByLabel('Appointment date').fill(addDays(branchToday(), 1))
  const none = form.getByTestId('no-free-slots')
  await expect(none).toContainText('No free slots on this day. Try another date')
  await expect(none.getByRole('link', { name: 'check working hours' })).toHaveAttribute('href', '/admin/working-hours')
  await shot(page, info, 'booking-no-free-slots')
})
