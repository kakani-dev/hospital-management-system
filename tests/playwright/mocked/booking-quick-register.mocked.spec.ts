import { expect, test, type Page, type TestInfo } from '@playwright/test'
import { MockBackend, addDays, branchToday, ids, practitionerIds, signIn } from './mock-backend'

/**
 * Inline quick-register in the Book appointment drawer (mobile width, Mohith 20 Oct): "+ New patient"
 * expands the shared register form (compact) inside the drawer; Save & book registers (server MRN)
 * and books in one action without losing the slot. Recent patients show on focus (no extra tap).
 * BOOKING_SHOTS_DIR=<dir> also saves the screenshots there.
 */
let backend: MockBackend
test.use({ viewport: { width: 412, height: 915 }, hasTouch: true, isMobile: true })

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

async function shot(page: Page, info: TestInfo, name: string) {
  const dir = process.env.BOOKING_SHOTS_DIR
  const body = await page.screenshot({ ...(dir ? { path: `${dir}/${name}.png` } : {}) })
  await info.attach(name, { body, contentType: 'image/png' })
}

async function openWithSlot(page: Page) {
  await signIn(page, 'admin@alpha.example')
  await page.goto(`/appointments?branch=${ids.alphaMain}`)
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const form = page.getByRole('form', { name: 'Book appointment' })
  await form.getByLabel('Practitioner').selectOption(practitionerIds.rao)
  await form.getByLabel('Appointment date').fill(addDays(branchToday(), 1))
  await form.getByText('09:00', { exact: true }).click()
  return form
}

test('mobile: recent patients on focus, then "+ New patient" → Save & book in 3 taps, slot kept', async ({ page }, info) => {
  const form = await openWithSlot(page)
  let taps = 0
  const tap = async (l: ReturnType<Page['getByRole']>) => {
    taps++
    await l.click()
  }
  const search = form.getByLabel('Find patient')
  await tap(search)
  await expect(form.getByRole('listbox', { name: 'Recent patients' })).toBeVisible()
  await shot(page, info, 'quick-1-recent-on-focus')
  await search.pressSequentially('Zz-Mobile Synthetic')
  const option = form.getByTestId('register-new-patient')
  await expect(option).toHaveText('+ New patient “Zz-Mobile Synthetic”')
  await shot(page, info, 'quick-2-new-patient-option')
  await tap(option)
  const quick = form.getByTestId('quick-register')
  await expect(quick.getByLabel('First name')).toHaveValue('Zz-Mobile')
  await expect(quick.getByLabel('Last name')).toHaveValue('Synthetic')
  await expect(quick.getByLabel('First name')).not.toBeFocused() // name pre-filled → focus moves on
  await expect(quick.getByLabel('Same as phone number')).toBeChecked()
  await quick.getByLabel(/Phone/).fill('+91 98450 55501')
  await shot(page, info, 'quick-3-inline-form')
  await expect(form.getByRole('radio', { name: '09:00' })).toBeChecked()
  await tap(quick.getByTestId('save-and-book'))
  await expect(page.getByText(/Booked Zz-Mobile Synthetic with/)).toBeVisible()
  await shot(page, info, 'quick-4-booked')
  expect(taps).toBe(3)
  const created = backend.patients.find((p) => p.firstName === 'Zz-Mobile')!
  expect(created.mrn).toMatch(/^ALPHA-\d{6}$/)
  expect(created.registeredBranchId).toBe(ids.alphaMain)
  expect(created.whatsapp).toBe('same')
  expect(page.url()).toContain('/appointments')

  // Recent = latest registration/booking first (GET /patients?sort=recent): the new patient tops the list.
  await page.getByRole('button', { name: 'Book appointment' }).click()
  const again = page.getByRole('form', { name: 'Book appointment' })
  await again.getByLabel('Find patient').click()
  await expect(again.getByRole('listbox', { name: 'Recent patients' }).getByTestId('patient-option').first()).toContainText('Synthetic, Zz-Mobile')
})

test('mobile: phone search pre-fills +91; a duplicate phone offers "Use existing"', async ({ page }, info) => {
  const form = await openWithSlot(page)
  await form.getByLabel('Find patient').fill('98450 00002')
  await form.getByTestId('register-new-patient').click()
  const quick = form.getByTestId('quick-register')
  await expect(quick.getByLabel(/Phone/)).toHaveValue('+91 98450 00002')
  await expect(quick.getByLabel('First name')).toBeFocused()
  await page.keyboard.type('Zz-Dup')
  await page.keyboard.press('Tab')
  await page.keyboard.type('Synthetic')
  await page.keyboard.press('Enter') // Enter = Save & book (slot chosen); never submits the outer form
  await expect(form.getByTestId('duplicate-warning')).toBeVisible()
  await shot(page, info, 'quick-5-duplicate')
  const before = backend.patients.length
  await form.getByTestId('use-existing').click()
  await expect(form.getByTestId('picked-patient')).toContainText('Synthetic-Alpha, Ravi')
  await expect(form.getByRole('button', { name: 'Confirm booking' })).toBeFocused()
  await expect(form.getByRole('radio', { name: '09:00' })).toBeChecked()
  expect(backend.patients.length).toBe(before)
})
