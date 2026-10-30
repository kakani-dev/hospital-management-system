import { expect, test, type APIRequestContext } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * #71 OP billing journey against the real API (web + microservices + Postgres/RLS), REG-025 / REG-039:
 * check-in opens the consult bill -> finalize -> collect cash with change -> receipt -> close the
 * counter session -> the day-end screen shows it closed and the admin reconciles it.
 *
 * Fixtures go through the API: a fresh practitioner with a schedule for the branch-local today, a
 * fresh Zz- patient and a booking in the first free slot, so nothing depends on seed rows or the clock.
 * Closing a drawer has no screen yet, so that one step is an API call as the cashier.
 */

interface Branch { id: string; timezone: string }
interface Slot { startsAt: string; endsAt: string }
interface DaySession { sessionId: string; status: string; expectedCashPaise: number }

const rupees = (paise: number) => `₹${(paise / 100).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`

function branchToday(timeZone: string) {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
      .formatToParts(new Date())
      .map((x) => [x.type, x.value]),
  )
  return {
    date: `${p.year}-${p.month}-${p.day}`,
    weekday: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(p.weekday ?? '') + 1,
    minutes: Number(p.hour) * 60 + Number(p.minute),
  }
}

async function bookedToday(request: APIRequestContext) {
  const admin = bearer(await tokenFor(request, users.alphaAdmin))
  const reception = bearer(await tokenFor(request, users.alphaReception))
  const branches = (await (await request.get('/api/v1/branches', { headers: admin })).json()) as Branch[]
  const main = branches.find((b) => b.id === ids.alphaMain)!
  const now = branchToday(main.timezone)
  test.skip(now.minutes > 23 * 60 + 20, 'too close to branch-local midnight for a same-day slot')

  const practitioner = await request.post('/api/v1/practitioners', {
    headers: admin,
    data: { displayName: `Dr ${unique('Bill')} (synthetic)`, specialty: 'General Medicine' },
  })
  expect(practitioner.status()).toBe(201)
  const practitionerId = ((await practitioner.json()) as { id: string }).id
  const schedule = await request.post('/api/v1/schedules', {
    headers: admin,
    data: { practitionerId, branchId: ids.alphaMain, weekday: now.weekday, startTime: '00:00', endTime: '23:55', slotMinutes: 5, validFrom: now.date, validTo: now.date },
  })
  expect(schedule.status()).toBe(201)

  const lastName = `Zz-E2E-${unique('Bill')}`
  const patient = await request.post('/api/v1/patients', {
    headers: reception,
    data: { firstName: 'Billing', lastName, registeredBranchId: ids.alphaMain, sex: 'female', ageYears: 30, noPhoneReason: 'test fixture' },
  })
  expect(patient.status()).toBe(201)
  const patientId = ((await patient.json()) as { id: string }).id

  const slots = (await (
    await request.get(`/api/v1/slots?branchId=${ids.alphaMain}&from=${now.date}&to=${now.date}&practitionerId=${practitionerId}&durationMinutes=15`, { headers: reception })
  ).json()) as Slot[]
  expect(slots.length, 'a free slot today').toBeGreaterThan(0)
  const booking = await request.post('/api/v1/appointments', {
    headers: reception,
    data: { branchId: ids.alphaMain, practitionerId, patientId, startsAt: slots[0]!.startsAt, endsAt: slots[0]!.endsAt },
  })
  expect(booking.status()).toBe(201)
  return { reception, admin, lastName, fullName: `Billing ${lastName}`, today: now.date }
}

test.describe('OP billing journey (full stack)', () => {
  test('check-in -> bill -> cash with change -> receipt -> close session -> reconcile', async ({ page, browser, request }) => {
    const { reception, lastName, fullName, today } = await bookedToday(request)

    // The cashier's drawer for today (opened on demand, the same way the bill drawer does).
    const ensured = await request.post('/api/v1/counter-sessions/ensure', { headers: reception, data: { branchId: ids.alphaMain } })
    expect(ensured.status()).toBe(200)
    const sessionId = ((await ensured.json()) as { id: string }).id
    const dayEnd = async () =>
      ((await (await request.get(`/api/v1/billing-reports/day-end?branchId=${ids.alphaMain}&date=${today}`, { headers: reception })).json()) as DaySession[])
        .find((s) => s.sessionId === sessionId)
    const expectedBefore = (await dayEnd())!.expectedCashPaise

    // 1. Check in: the consult bill opens in the drawer.
    await signIn(page, users.alphaReception)
    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Check-in', exact: true }).click()
    await page.getByRole('button', { name: new RegExp(`^Check in ${fullName} at `) }).click()
    await expect(page.getByTestId('token-number')).toBeVisible()
    const drawer = page.getByTestId('billing-drawer')
    await expect(drawer).toBeVisible()
    await expect(drawer.getByTestId('billing-panel-patient-name')).toContainText(lastName)
    await expect(drawer.getByTestId('bill-line').filter({ hasText: 'OP consultation' })).toHaveCount(1)

    // 2. Finalize, then take cash with more than due: change is shown, then Paid with a receipt number.
    const finalized = page.waitForResponse((r) => /\/api\/v1\/bills\/[^/]+\/finalize$/.test(r.url()))
    await drawer.getByTestId('finalize-bill').click()
    const bill = (await (await finalized).json()) as { billNo: string; totalPaise: number; duePaise: number }
    expect(bill.billNo).toBeTruthy()
    expect(bill.duePaise).toBe(bill.totalPaise)
    await expect(drawer.getByTestId('bill-due')).toContainText(rupees(bill.duePaise))
    await drawer.getByTestId('billing-collect-mode-cash').click()
    await drawer.getByTestId('billing-collect-received').fill(String(bill.duePaise / 100 + 100))
    await expect(drawer.getByTestId('billing-collect-change')).toHaveText(`Change due ${rupees(10000)}`)
    const paid = page.waitForResponse((r) => r.url().endsWith('/api/v1/payments') && r.request().method() === 'POST')
    await drawer.getByTestId('collect-cash').click()
    const payment = await paid
    expect(payment.status()).toBe(200)
    const receipt = (await payment.json()) as { id: string; counterSessionId: string; amountPaise: number }
    expect(receipt.counterSessionId).toBe(sessionId)
    expect(receipt.amountPaise).toBe(bill.totalPaise)
    await expect(drawer.getByTestId('paid-status')).toHaveText('Paid')

    // 3. Receipt: bill number, patient, amount and cash tender.
    await drawer.getByTestId('billing-panel-view-receipt').click()
    await expect(page.getByTestId('receipt')).toBeVisible()
    await expect(page.getByTestId('billing-receipt-bill-no')).toHaveText(bill.billNo)
    await expect(page.getByTestId('billing-receipt-patient')).toContainText(lastName)
    await expect(page.getByTestId('billing-receipt-amount')).toContainText(rupees(bill.totalPaise))
    await expect(page.getByTestId('billing-receipt-tenders')).toContainText('Cash')

    // 4. Close the drawer: expected cash moved by exactly this payment (change is not kept).
    const expected = expectedBefore + bill.totalPaise
    const closed = await request.post(`/api/v1/counter-sessions/${sessionId}/close`, { headers: reception, data: { countedCashPaise: expected } })
    expect(closed.status()).toBe(200)
    expect(await closed.json()).toMatchObject({ status: 'closed', expectedCashPaise: expected, variancePaise: 0 })
    const again = await request.post(`/api/v1/counter-sessions/${sessionId}/close`, { headers: reception, data: { countedCashPaise: expected } })
    expect(again.status()).toBe(409)

    // 5. Day end (admin, own signed-in context): the session is closed, then reconciled.
    const adminContext = await browser.newContext()
    const adminPage = await adminContext.newPage()
    await signIn(adminPage, users.alphaAdmin)
    await adminPage.goto(`/billing/day-end?branch=${ids.alphaMain}`)
    await adminPage.getByLabel('Business date').fill(today)
    const row = adminPage.locator(`[data-testid="day-end-session"][data-session-id="${sessionId}"]`)
    await expect(row.getByTestId('session-status')).toHaveText('closed')
    await expect(row.getByTestId('session-expected')).toHaveText(`Expected ${rupees(expected)}`)
    await row.getByRole('button', { name: 'Reconcile' }).click()
    await expect(row.getByTestId('session-status')).toHaveText('reconciled')
    expect((await dayEnd())!.status).toBe('reconciled')
    await adminContext.close()
  })
})
