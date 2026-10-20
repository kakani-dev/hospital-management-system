import { expect, test } from '@playwright/test'
import { MockBackend, signIn } from './mock-backend'

/** Reception keyboard flow: global shortcuts and the type-ahead patient combobox (mocked API). */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

test('shortcuts: Alt+C / Alt+W / Alt+Q / Alt+N, "/" search and the "?" help dialog', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')

  await page.keyboard.press('Alt+KeyC')
  await expect(page.getByRole('heading', { name: 'Reception check-in' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Check in Asha Synthetic-Alpha at 09:30' })).toBeFocused()

  // Walk-in entirely from the keyboard
  await page.keyboard.press('Alt+KeyW')
  const box = page.getByRole('combobox', { name: 'Find walk-in patient' })
  await expect(box).toBeFocused()
  await page.keyboard.type('Synthetic')
  await expect(page.getByRole('listbox', { name: 'Matching patients' }).getByRole('option')).toHaveCount(2)
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('Enter')
  await expect(page.getByTestId('picked-patient')).toContainText('Synthetic-Alpha, Ravi')
  await page.getByRole('button', { name: 'Issue walk-in token' }).focus()
  await page.keyboard.press('Enter')
  await expect(page.getByTestId('token-number')).toHaveText('1')
  await expect(page.getByTestId('token-issued')).toBeFocused()

  await page.keyboard.press('Alt+KeyQ')
  await expect(page.getByRole('heading', { name: 'OPD queue' })).toBeVisible()

  await page.keyboard.press('/')
  await expect(page.getByLabel('Search patients')).toBeFocused()
  await page.keyboard.type('Asha')
  await expect(page.getByLabel('Search patients')).toHaveValue('Asha') // "/" and letters type normally in fields

  await page.keyboard.press('Alt+KeyN')
  await expect(page.getByRole('form', { name: 'Register patient' })).toBeVisible()
  await expect(page.getByLabel('First name')).toBeFocused() // no MRN input: it is generated
  await expect(page.getByLabel('MRN')).toHaveCount(0)

  await page.getByRole('heading', { name: /register/i }).first().click()
  await page.keyboard.press('Shift+Slash')
  const help = page.getByRole('dialog', { name: 'Keyboard shortcuts' })
  await expect(help).toContainText('Alt+W')
  await page.keyboard.press('Escape')
  await expect(help).toHaveCount(0)
})

test('a doctor gets only the shortcuts of their role', async ({ page }) => {
  await signIn(page, 'doctor@alpha.example')
  await page.keyboard.press('Alt+KeyC')
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  // RBAC: doctors do not book, so Alt+K does nothing either
  await page.keyboard.press('Alt+KeyK')
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await expect(page.getByRole('form', { name: 'Book appointment' })).toHaveCount(0)
  await page.keyboard.press('Alt+KeyQ')
  await expect(page).toHaveURL(/\/queue/)
})

test('combobox: no match → register new (pre-filled, nothing in the URL) → back with the patient selected', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.keyboard.press('Alt+KeyW')
  const box = page.getByRole('combobox', { name: 'Find walk-in patient' })
  await expect(box).toBeFocused()
  await page.keyboard.type('Synthetic-New, Kiran')
  const register = page.getByTestId('register-new-patient')
  await expect(register).toContainText('No match: register new patient “Synthetic-New, Kiran”')
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('Enter')

  await expect(page.getByRole('form', { name: 'Register patient' })).toBeVisible()
  expect(page.url()).not.toContain('Kiran')
  await expect(page.getByLabel('First name')).toHaveValue('Kiran')
  await expect(page.getByLabel('Last name')).toHaveValue('Synthetic-New')
  await expect(page.getByLabel('Date of birth')).toBeFocused() // first empty field; no MRN input
  await page.getByRole('button', { name: /register patient/i }).click()

  await expect(page.getByRole('heading', { name: 'Reception check-in' })).toBeVisible()
  await expect(page.getByTestId('picked-patient')).toContainText('Synthetic-New, Kiran ALPHA-000001')
  await expect(page.getByRole('button', { name: 'Issue walk-in token' })).toBeFocused()
  await page.keyboard.press('Enter')
  await expect(page.getByTestId('token-number')).toHaveText('1')
  const created = backend.patients.find((p) => p.mrn === 'ALPHA-000001')!
  expect(backend.calls.find((c) => c.path === '/api/v1/queue/walk-in')!.body).toMatchObject({ patientId: created.id })
  expect(backend.calls.filter((c) => /Kiran/.test(c.url))).toEqual([])
})
