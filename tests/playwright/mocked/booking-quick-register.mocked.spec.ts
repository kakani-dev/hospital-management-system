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
  await expect(option).toHaveText('+ Add new patient “Zz-Mobile Synthetic”')
  await shot(page, info, 'quick-2-new-patient-option')
  await tap(option)
  const quick = page.getByTestId('quick-register')
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
  const quick = page.getByTestId('quick-register')
  await expect(quick.getByLabel(/Phone/)).toHaveValue('+91 98450 00002')
  await expect(quick.getByLabel('First name')).toBeFocused()
  await page.keyboard.type('Zz-Dup')
  await page.keyboard.press('Tab')
  await page.keyboard.type('Synthetic')
  await page.keyboard.press('Enter') // Enter = Save & book (slot chosen); never submits the outer form
  await expect(page.getByTestId('duplicate-warning')).toBeVisible()
  await shot(page, info, 'quick-5-duplicate')
  const before = backend.patients.length
  await page.getByTestId('use-existing').click()
  await expect(form.getByTestId('picked-patient')).toContainText('Synthetic-Alpha, Ravi')
  await expect(form.getByRole('button', { name: 'Confirm booking' })).toBeFocused()
  await expect(form.getByRole('radio', { name: '09:00' })).toBeChecked()
  expect(backend.patients.length).toBe(before)
})

// Stacked "Add new patient" drawer (Mohith 26 Oct): the existing register form in the existing Drawer, on top of the booking drawer.
test.describe('Add new patient drawer over the booking drawer', () => {
  async function openAdd(page: Page, term: string) {
    const form = await openWithSlot(page)
    await form.getByLabel('Find patient').fill(term)
    await expect(form.getByTestId('register-new-patient')).toHaveText(`+ Add new patient “${term}”`)
    await form.getByTestId('register-new-patient').click()
    const drawer = page.getByTestId('add-patient-drawer')
    await expect(drawer.getByTestId('quick-register')).toBeVisible()
    return { form, drawer }
  }
  const slotKept = async (form: ReturnType<Page['getByRole']>) => {
    await expect(form.getByLabel('Practitioner')).toHaveValue(practitionerIds.rao)
    await expect(form.getByLabel('Appointment date')).toHaveValue(addDays(branchToday(), 1))
    await expect(form.getByRole('radio', { name: '09:00' })).toBeChecked()
  }

  test('create closes the drawer, selects the new patient and keeps practitioner, date and slot', async ({ page }) => {
    const { form, drawer } = await openAdd(page, 'Zz-Stack Synthetic')
    await drawer.getByLabel(/Phone/).fill('+91 98450 55601')
    await drawer.getByTestId('save-patient').click()
    await expect(drawer).toBeHidden()
    await expect(form.getByTestId('picked-patient')).toContainText('Synthetic, Zz-Stack')
    await slotKept(form)
  })

  test('double-submit creates one patient', async ({ page }) => {
    backend.fault({ method: 'POST', path: '/api/v1/patients', delayMs: 800 })
    const { drawer } = await openAdd(page, 'Zz-Double Synthetic')
    const save = drawer.getByTestId('save-patient')
    await save.click()
    await expect(save).toBeDisabled()
    await save.click({ force: true }).catch(() => {})
    await expect(drawer).toBeHidden()
    expect(backend.patients.filter((p) => p.firstName === 'Zz-Double')).toHaveLength(1)
  })

  test('validation errors stay in the drawer and nothing is created', async ({ page }) => {
    const { drawer } = await openAdd(page, 'Zz-Valid')
    await drawer.getByTestId('save-patient').click()
    await expect(drawer.getByTestId('quick-register')).toBeVisible()
    await expect(drawer.getByText(/last name/i).first()).toBeVisible()
    expect(backend.patients.some((p) => p.firstName === 'Zz-Valid')).toBe(false)
  })

  test('cancel closes only the add drawer and keeps the booking state', async ({ page }) => {
    const { form, drawer } = await openAdd(page, 'Zz-Cancel Synthetic')
    await drawer.getByRole('button', { name: 'Cancel' }).click()
    await expect(drawer).toBeHidden()
    await expect(page.getByTestId('booking-drawer')).toBeVisible()
    await slotKept(form)
    await expect(form.getByTestId('picked-patient')).toHaveCount(0)
  })

  test('API failure shows an error and keeps the typed form', async ({ page }) => {
    backend.fault({ method: 'POST', path: '/api/v1/patients', status: 500 })
    const { drawer } = await openAdd(page, 'Zz-Fail Synthetic')
    await drawer.getByLabel(/Phone/).fill('+91 98450 55602')
    await drawer.getByTestId('save-patient').click()
    await expect(drawer.getByRole('alert').first()).toBeVisible()
    await expect(drawer.getByLabel('First name')).toHaveValue('Zz-Fail')
    await expect(drawer.getByLabel(/Phone/)).toHaveValue('+91 98450 55602')
  })

  test('MRN-like search text pre-fills nothing; phone-like pre-fills the phone', async ({ page }) => {
    const { drawer } = await openAdd(page, 'ALPHA-999999')
    await expect(drawer.getByLabel('First name')).toHaveValue('')
    await expect(drawer.getByLabel('Last name')).toHaveValue('')
    await expect(drawer.getByLabel(/Phone/)).toHaveValue('')
  })
})
