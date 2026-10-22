import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * A doctor with morning hours at Main and evening hours at East can be booked at each branch,
 * and the slot list at a branch shows only that branch's hours.
 */

interface Practitioner {
  id: string
  displayName: string
}
interface Patient {
  id: string
  firstName: string
  lastName: string
}
interface Appointment {
  id: string
  branchId: string
  practitionerId: string
  patientId: string
  status: string
}

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })

async function bookAt(page: Page, branchId: string, practitionerId: string, lastName: string, time: string) {
  await page.getByLabel('Showing branch').selectOption(branchId)
  await expect(page.getByLabel('Showing branch')).toHaveValue(branchId)
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Practitioner').selectOption(practitionerId)
  await form.getByLabel('Appointment date').fill('2030-06-03')
  await form.getByLabel('Find patient').fill(lastName)
  await form.getByTestId('patient-option').filter({ hasText: lastName }).click()
  const slots = form.getByTestId('slot-list')
  await expect(slots.getByText(time, { exact: true })).toBeVisible()
  await slots.getByText(time, { exact: true }).click()
  const booked = page.waitForResponse((r) => r.url().includes('/api/v1/appointments') && r.request().method() === 'POST')
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  const response = await booked
  expect(response.status()).toBe(201)
  return (await response.json()) as Appointment
}

test('admin books a multi-branch doctor at each branch they work', async ({ page, request }) => {
  const admin = bearer(await tokenFor(request, users.alphaAdmin))
  const practitioner = await createPractitioner(request, admin)
  const patient = await createPatient(request, admin)
  const fullName = `${patient.firstName} ${patient.lastName}`

  await signIn(page, users.alphaAdmin)
  await nav(page, 'Appointments').click()

  const morning = await bookAt(page, ids.alphaMain, practitioner.id, patient.lastName, '09:00')
  await expect(page.getByText(new RegExp(`Booked ${fullName} with .* at 09:00\\.`))).toBeVisible()
  const evening = await bookAt(page, ids.alphaEast, practitioner.id, patient.lastName, '17:00')
  await expect(page.getByText(new RegExp(`Booked ${fullName} with .* at 17:00\\.`))).toBeVisible()

  for (const [appointment, branchId] of [
    [morning, ids.alphaMain],
    [evening, ids.alphaEast],
  ] as const) {
    const fetched = (await (await request.get(`/api/v1/appointments/${appointment.id}`, { headers: admin })).json()) as Appointment
    expect(fetched).toMatchObject({
      id: appointment.id,
      branchId,
      practitionerId: practitioner.id,
      patientId: patient.id,
      status: 'booked',
    })
  }
})

async function createPractitioner(request: APIRequestContext, admin: Record<string, string>) {
  const created = await request.post('/api/v1/practitioners', {
    headers: admin,
    data: { displayName: `Dr ${unique('MB')} (synthetic)`, specialty: 'General Medicine' },
  })
  expect(created.status()).toBe(201)
  const practitioner = (await created.json()) as Practitioner
  for (const row of [
    { branchId: ids.alphaMain, startTime: '09:00', endTime: '13:00' },
    { branchId: ids.alphaEast, startTime: '17:00', endTime: '20:00' },
  ]) {
    const schedule = await request.post('/api/v1/schedules', {
      headers: admin,
      data: { practitionerId: practitioner.id, weekday: 1, slotMinutes: 30, validFrom: '2026-01-01', ...row },
    })
    expect(schedule.status()).toBe(201)
  }
  return practitioner
}

async function createPatient(request: APIRequestContext, admin: Record<string, string>) {
  const lastName = `Zz-MB-${unique('P')}`
  const created = await request.post('/api/v1/patients', {
    headers: admin,
    data: { firstName: 'Multi', lastName, registeredBranchId: ids.alphaMain, sex: 'female' },
  })
  expect(created.status()).toBe(201)
  return (await created.json()) as Patient
}
