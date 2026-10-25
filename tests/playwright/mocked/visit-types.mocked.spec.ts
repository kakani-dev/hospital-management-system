import { expect, test } from '@playwright/test'
import { MockBackend, addDays, branchInstant, branchToday, ids, patientIds, practitionerIds, signIn } from './mock-backend'

/**
 * Visit type on the booking form. The mock flag is off in every other spec so those POST bodies
 * stay free of visitTypeId.
 */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  backend.visitTypes = true
  await backend.install(context)
})

test('suggests a free follow-up and sends the visit type length', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  const tomorrow = addDays(branchToday(), 1)
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  await form.getByLabel('Appointment date').fill(tomorrow)
  await form.getByLabel('Find patient').fill('Asha')
  await form.getByRole('option', { name: /Synthetic-Alpha, Asha/ }).click()
  await expect(form.getByLabel('Visit type')).toHaveValue('v1000000-0000-4000-8000-000000000002')
  await expect(form.getByTestId('visit-fee')).toContainText('₹0')
  await form.getByText('09:00', { exact: true }).click()
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  await expect(page.getByText(/Booked Asha Synthetic-Alpha/)).toBeVisible()
  const start = branchInstant(tomorrow, '09:00')
  const post = backend.calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/appointments').at(-1)!
  expect(post.body).toMatchObject({
    branchId: ids.alphaMain,
    practitionerId: practitionerIds.rao,
    patientId: patientIds.asha,
    startsAt: start,
    endsAt: new Date(Date.parse(start) + 30 * 60_000).toISOString(),
    visitTypeId: 'v1000000-0000-4000-8000-000000000002',
  })
})
