import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * Sprint 2 full stack (web + API + real Postgres/RLS, SPRINT2-CONTRACT.md DB v4 + API v2):
 * a receptionist books an appointment in the calendar, checks the patient in at the reception desk
 * and finds them on the OPD queue board with the issued token.
 *
 * Fixtures go through the API (never the DB): a fresh practitioner with a schedule for the
 * branch-local today (so there is always a free future slot and no collision with other specs or
 * reruns) and a fresh patient. Sessions are per tab (sessionStorage), so everything runs in one tab.
 */

interface Branch {
  id: string
  timezone: string
}
interface Practitioner {
  id: string
  displayName: string
}
interface Patient {
  id: string
  mrn: string
  firstName: string
  lastName: string
  registeredBranchId?: string
}
interface QueueEntry {
  id: string
  tokenNo: number
  patientId: string
  appointmentId: string | null
  status: string
}

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name, exact: true })

/** Branch-local calendar date (YYYY-MM-DD), ISO weekday (1 = Mon) and minutes since midnight. */
function branchNow(timeZone: string) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      weekday: 'short',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  )
  const weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(parts.weekday ?? '') + 1
  return { date: `${parts.year}-${parts.month}-${parts.day}`, weekday, minutes: Number(parts.hour) * 60 + Number(parts.minute) }
}

async function setUp(request: APIRequestContext) {
  const admin = bearer(await tokenFor(request, users.alphaAdmin))
  const reception = bearer(await tokenFor(request, users.alphaReception))

  const branches = (await (await request.get('/api/v1/branches', { headers: admin })).json()) as Branch[]
  const main = branches.find((b) => b.id === ids.alphaMain)
  expect(main, 'Alpha Main branch').toBeTruthy()
  const now = branchNow(main!.timezone)
  // Slots are only offered in the future and schedules can't cross midnight (contract §2.2/2.3).
  test.skip(now.minutes > 23 * 60 + 40, 'too close to branch-local midnight for a same-day slot')

  const practitionerResponse = await request.post('/api/v1/practitioners', {
    headers: admin,
    data: { displayName: `Dr ${unique('E2E')} (synthetic)`, specialty: 'General Medicine' },
  })
  expect(practitionerResponse.status()).toBe(201)
  const practitioner = (await practitionerResponse.json()) as Practitioner

  const scheduleResponse = await request.post('/api/v1/schedules', {
    headers: admin,
    data: {
      practitionerId: practitioner.id,
      branchId: ids.alphaMain,
      weekday: now.weekday,
      startTime: '00:00',
      endTime: '23:55',
      slotMinutes: 5,
      validFrom: now.date,
      validTo: now.date,
    },
  })
  expect(scheduleResponse.status()).toBe(201)

  // 'Zz-' sorts after the seed's Synthetic-* rows, so other specs' first-page assertions are unaffected.
  const lastName = `Zz-E2E-${unique('S2')}`
  const patientResponse = await request.post('/api/v1/patients', {
    headers: reception,
    data: { firstName: 'Queue', lastName, registeredBranchId: ids.alphaMain, sex: 'female' },
  })
  expect(patientResponse.status()).toBe(201)
  const patient = (await patientResponse.json()) as Patient

  return { reception, practitioner, patient, today: now.date, timeZone: main!.timezone }
}

test.describe('Sprint 2: book -> check in -> OPD queue', () => {
  test('receptionist books today, checks the patient in and finds them on the queue board', async ({ page, request }) => {
    const { reception, practitioner, patient, today } = await setUp(request)
    const fullName = `${patient.firstName} ${patient.lastName}`

    await signIn(page, users.alphaReception)

    // 1. Book in the calendar (receptionist is bound to Alpha Main).
    await nav(page, 'Appointments').click()
    await expect(page.getByLabel('Showing branch')).toHaveValue(ids.alphaMain)
    await page.getByRole('button', { name: 'Book appointment' }).click()
    const form = page.getByRole('form', { name: 'Book appointment' })
    await form.getByLabel('Practitioner').selectOption(practitioner.id)
    await form.getByLabel('Appointment date').fill(today)
    await form.getByLabel('Find patient').fill(patient.lastName)
    await form.getByRole('option', { name: new RegExp(patient.lastName) }).click()

    const firstSlot = form.getByTestId('slot-list').locator('label').first()
    await expect(firstSlot).toBeVisible()
    const slotTime = (await firstSlot.innerText()).trim()
    expect(slotTime).toMatch(/^\d{2}:\d{2}$/)
    await firstSlot.click()

    const booked = page.waitForResponse((r) => r.url().endsWith('/api/v1/appointments') && r.request().method() === 'POST')
    await form.getByRole('button', { name: 'Confirm booking' }).click()
    const bookedResponse = await booked
    expect(bookedResponse.status()).toBe(201)
    const appointment = (await bookedResponse.json()) as { id: string; status: string; patientId: string; practitionerId: string }
    expect(appointment).toMatchObject({ status: 'booked', patientId: patient.id, practitionerId: practitioner.id })
    await expect(page.getByText(new RegExp(`Booked ${fullName} with .* at ${slotTime}\\.`))).toBeVisible()

    // 2. Check in at the reception desk: the appointment is listed for today; a token is issued.
    await nav(page, 'Check-in').click()
    const checkInButton = page.getByRole('button', { name: `Check in ${fullName} at ${slotTime}` })
    await expect(checkInButton).toBeVisible()
    const checkedIn = page.waitForResponse((r) => r.url().endsWith(`/api/v1/appointments/${appointment.id}/check-in`))
    await checkInButton.click()
    const checkInResponse = await checkedIn
    expect(checkInResponse.status()).toBe(201)
    const result = (await checkInResponse.json()) as { queueEntryId: string; tokenNo: number; queueDate: string }
    expect(result.queueDate).toBe(today)
    await expect(page.getByTestId('token-number')).toHaveText(String(result.tokenNo))
    await expect(page.getByTestId('token-issued')).toContainText(fullName)
    await expect(checkInButton).toHaveCount(0) // no longer "booked"

    // 3. Find them on the OPD queue board, waiting, with that token.
    await nav(page, 'OPD queue').click()
    await expect(page.getByLabel('Showing branch')).toHaveValue(ids.alphaMain)
    const entry = page.getByTestId('queue-waiting').locator(`[data-testid="queue-entry"][data-token="${result.tokenNo}"]`)
    await expect(entry).toContainText(`${patient.lastName}, ${patient.firstName}`)
    await expect(entry).toContainText(practitioner.displayName)
    await expect(entry).toContainText('appointment')

    // The API agrees: the entry is on today's board, linked to the appointment, and the appointment moved on.
    const board = (await (await request.get(`/api/v1/queue?branchId=${ids.alphaMain}`, { headers: reception })).json()) as QueueEntry[]
    expect(board.find((e) => e.id === result.queueEntryId)).toMatchObject({
      tokenNo: result.tokenNo,
      patientId: patient.id,
      appointmentId: appointment.id,
      status: 'waiting',
    })
    const tokens = board.map((e) => e.tokenNo)
    expect(tokens).toEqual([...tokens].sort((a, b) => a - b))
    const after = (await (await request.get(`/api/v1/appointments/${appointment.id}`, { headers: reception })).json()) as { status: string }
    expect(after.status).toBe('checked_in')

    // 4. Follow-up: call in, mark done, then "Book follow-up" pre-fills the patient and practitioner.
    await entry.getByRole('button', { name: `Call in token ${result.tokenNo}` }).click()
    const inRoom = page.getByTestId('queue-in_consultation').locator(`[data-testid="queue-entry"][data-token="${result.tokenNo}"]`)
    await inRoom.getByRole('button', { name: `Mark done token ${result.tokenNo}` }).click()
    const done = page.getByTestId('queue-done').locator(`[data-testid="queue-entry"][data-token="${result.tokenNo}"]`)
    await done.getByRole('link', { name: 'Book follow-up' }).click()
    await expect(page).toHaveURL(/\/appointments/)
    const fu = page.getByRole('form', { name: 'Book appointment' })
    await expect(fu.getByLabel('Practitioner')).toHaveValue(practitioner.id)
    await expect(fu).toContainText(`${patient.lastName}, ${patient.firstName}`)
    const fuSlot = fu.getByTestId('slot-list').locator('label').first()
    await expect(fuSlot).toBeVisible()
    await fuSlot.click()
    const fuBooked = page.waitForResponse((r) => r.url().endsWith('/api/v1/appointments') && r.request().method() === 'POST')
    await fu.getByRole('button', { name: 'Confirm booking' }).click()
    const fuResponse = await fuBooked
    expect(fuResponse.status()).toBe(201)
    expect(await fuResponse.json()).toMatchObject({ patientId: patient.id, practitionerId: practitioner.id, status: 'booked' })
  })
})

test.describe('Booking drawer quick-register (full stack)', () => {
  test('receptionist creates a Zz- patient inline from "+ New patient" and books it with Save & book', async ({ page, request }) => {
    const { reception, practitioner, today } = await setUp(request)
    const lastName = `Zz-Quick-${unique('QR')}`
    await signIn(page, users.alphaReception)
    await nav(page, 'Appointments').click()
    await page.getByRole('button', { name: 'Book appointment' }).click()
    const form = page.getByRole('form', { name: 'Book appointment' })
    await form.getByLabel('Practitioner').selectOption(practitioner.id)
    await form.getByLabel('Appointment date').fill(today)
    const firstSlot = form.getByTestId('slot-list').locator('label').first()
    await firstSlot.click()
    await form.getByLabel('Find patient').fill(`Quick ${lastName}`)
    await form.getByTestId('register-new-patient').click()
    const quick = form.getByTestId('quick-register')
    // The term has digits (unique suffix), so it is treated as MRN-like and pre-fills nothing.
    await quick.getByLabel('First name').fill('Quick')
    await quick.getByLabel('Last name').fill(lastName)
    const created = page.waitForResponse((r) => r.url().endsWith('/api/v1/patients') && r.request().method() === 'POST')
    const booked = page.waitForResponse((r) => r.url().endsWith('/api/v1/appointments') && r.request().method() === 'POST')
    await quick.getByTestId('save-and-book').click()
    const patient = (await (await created).json()) as Patient
    expect(patient.registeredBranchId).toBe(ids.alphaMain)
    expect((await booked).status()).toBe(201)
    await expect(page.getByText(new RegExp(`Booked Quick ${lastName} with`))).toBeVisible()
    const appts = await request.get(`/api/v1/appointments?branchId=${ids.alphaMain}&from=${today}&to=${today}`, { headers: reception })
    expect(JSON.stringify(await appts.json())).toContain(patient.id)
  })
})

test.describe('@responsive mobile layout', () => {
  test('@responsive admin tables scroll inside their card; the page itself never scrolls sideways', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    for (const path of ['/admin/branches', '/admin/members', '/admin/practitioners', '/admin/working-hours', '/schedules']) {
      await page.goto(path)
      await expect(page.locator('table').first()).toBeVisible()
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      expect(overflow, path).toBeLessThanOrEqual(0)
    }
  })
})
