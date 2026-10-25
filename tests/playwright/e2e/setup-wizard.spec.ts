import { expect, test, type Page } from '@playwright/test'
import { PASSWORD, bearer, createSyntheticUser, tokenFor, unique } from './helpers'

/**
 * New hospital: public registration, operator approval, the setup wizard, then a first booking
 * on the calendar. Synthetic data only. The operator has no hospital, so sign-in lands on Hospitals.
 */
const OPERATOR = 'operator@medicore.example'

function prefixOf(code: string) {
  const alnum = code.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 4)
  return alnum || 'OP'
}

/** The next branch-local day, so every generated slot is still in the future. */
function nextBranchDay(timeZone: string) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short' })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  )
  const weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(parts.weekday ?? '') + 1
  const [year, month, day] = [parts.year, parts.month, parts.day].map(Number)
  const next = new Date(Date.UTC(year!, month! - 1, day! + 1))
  return { date: next.toISOString().slice(0, 10), weekday: weekday === 7 ? 1 : weekday + 1 }
}

async function signInTo(page: Page, email: string, heading: string) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible()
}

test('a new hospital finishes setup and books its first appointment', async ({ page, browser, request }) => {
  test.setTimeout(90_000)
  const contact = await createSyntheticUser('wizard')
  const name = `Synthetic ${unique('Wiz')}`.slice(0, 40)
  const code = unique('wiz').toLowerCase()

  await page.goto('/register-hospital')
  await page.getByLabel('Hospital name').fill(name)
  await page.getByLabel('Hospital time zone').fill('Asia/Kolkata')
  await page.getByLabel('City').fill('Pune')
  await page.getByLabel('Your name').fill('Wizard Synthetic')
  await page.getByLabel('Work email').fill(contact)
  await page.getByLabel('Phone').fill('+91 20 5550 0199')
  const sent = page.waitForResponse((r) => r.url().endsWith('/api/v1/public/hospital-signups'))
  await page.getByRole('button', { name: 'Send request' }).click()
  expect((await sent).status()).toBe(202)

  await signInTo(page, OPERATOR, 'Hospitals')
  await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Hospital requests', exact: true }).click()
  await page.getByRole('button', { name: `Approve ${name}` }).click()
  await page.getByRole('alertdialog').getByLabel('Hospital code').fill(code)
  await page.getByRole('alertdialog').getByRole('button', { name: 'Approve and create' }).click()
  const link = new URL(await page.getByTestId('invite-link-url').inputValue()).pathname

  const ctx = await browser.newContext()
  const tab = await ctx.newPage()
  await tab.goto(link)
  await tab.getByRole('button', { name: 'I already have a password' }).click()
  await tab.getByLabel('Email').fill(contact)
  await tab.getByLabel('Password').fill(PASSWORD)
  await tab.getByRole('button', { name: 'Sign in' }).click()
  await tab.getByRole('button', { name: `Join ${name}` }).click()

  await expect(tab.getByRole('heading', { name: 'Set up your hospital' })).toBeVisible()
  await expect(tab.getByLabel('Hospital name')).toHaveValue(name)
  await tab.getByRole('button', { name: 'Save and continue' }).click()

  await expect(tab.getByTestId('setup-doc-prefix')).toHaveText(prefixOf(code))
  await tab.getByLabel('Branch name').fill('Main Campus')
  await tab.getByLabel('Address').fill('1 Synthetic Road')
  await tab.getByRole('button', { name: 'Save and continue' }).click()

  const admin = bearer(await tokenFor(request, contact))
  const branches = (await (await request.get('/api/v1/branches', { headers: admin })).json()) as { id: string; timezone: string }[]
  const branch = branches[0]
  expect(branch, 'the default branch').toBeTruthy()
  const when = nextBranchDay(branch!.timezone)
  const doctor = await request.post('/api/v1/practitioners', {
    headers: admin,
    data: { displayName: `Dr ${unique('Wiz')} (synthetic)`, specialty: 'General Medicine' },
  })
  expect(doctor.status()).toBe(201)
  const practitioner = (await doctor.json()) as { id: string; displayName: string }
  const lastName = `Zz-${unique('Pt')}`
  const patientResponse = await request.post('/api/v1/patients', {
    headers: admin,
    data: { firstName: 'Asha', lastName, registeredBranchId: branch!.id, sex: 'female' },
  })
  expect(patientResponse.status()).toBe(201)
  const patient = (await patientResponse.json()) as { id: string; firstName: string; lastName: string }

  await tab.getByRole('button', { name: 'Continue' }).click()
  await tab.getByLabel('Practitioner').selectOption(practitioner.id)
  await tab.getByLabel('Weekday').selectOption(String(when.weekday))
  await tab.getByLabel('Start time').fill('00:00')
  await tab.getByLabel('End time').fill('23:30')
  await tab.getByLabel('Valid from').fill(when.date)
  await tab.getByRole('button', { name: 'Add hours' }).click()
  await expect(tab.getByText(/Added /)).toBeVisible()
  await tab.getByRole('button', { name: 'Skip' }).click()
  await tab.getByRole('button', { name: 'Go to the dashboard' }).click()
  await expect(tab.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await expect(tab.getByTestId('finish-setup')).toHaveCount(0)

  await tab.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Appointments', exact: true }).click()
  await tab.getByRole('button', { name: 'Book appointment' }).click()
  const form = tab.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Practitioner').selectOption(practitioner.id)
  await form.getByLabel('Appointment date').fill(when.date)
  await form.getByLabel('Find patient').fill(patient.lastName)
  await form.getByTestId('patient-option').filter({ hasText: patient.lastName }).click()
  const firstSlot = form.getByTestId('slot-list').locator('label').first()
  await expect(firstSlot).toBeVisible()
  await firstSlot.click()
  const booked = tab.waitForResponse((r) => r.url().endsWith('/api/v1/appointments') && r.request().method() === 'POST')
  await form.getByRole('button', { name: 'Confirm booking' }).click()
  expect((await booked).status()).toBe(201)
  await ctx.close()
})
