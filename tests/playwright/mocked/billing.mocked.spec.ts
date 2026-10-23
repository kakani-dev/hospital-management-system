import { expect, test } from '@playwright/test'
import { MockBackend, signIn } from './mock-backend'

/** OP billing drawer, UPI status, approvals and day-end (mocked API). */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

test('Alt+B raises an OP consult bill, then the UPI QR shows Paid', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.keyboard.press('Control+K')
  await page.getByTestId('command-palette-input').fill('Asha')
  await page.getByTestId('command-patient').first().click()
  await expect(page.getByTestId('patient-context')).toBeVisible()

  await page.keyboard.press('Alt+KeyB')
  await expect(page.getByTestId('billing-drawer')).toBeVisible()
  await expect(page.getByText('OP consultation')).toBeVisible()
  await expect(page.getByTestId('bill-total')).toHaveText('₹500.00')

  await page.getByTestId('finalize-bill').click()
  await page.getByRole('button', { name: 'Show UPI QR' }).click()
  await expect(page.getByRole('img', { name: 'UPI payment QR' })).toBeVisible()
  await expect(page.getByTestId('paid-status')).toHaveText('Paid', { timeout: 10_000 })
})

test('a payment link can be shared, and the public page opens the bill', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await page.keyboard.press('Control+K')
  await page.getByTestId('command-palette-input').fill('Asha')
  await page.getByTestId('command-patient').first().click()
  await page.getByTestId('context-op-consult').click()
  await page.getByTestId('finalize-bill').click()
  await page.getByRole('button', { name: 'Share payment link' }).click()
  await page.getByLabel('Phone').fill('+919800000000')
  await page.getByRole('button', { name: 'WhatsApp' }).click()
  await expect(page.getByText('Link queued')).toBeVisible()

  await page.goto('/pay/demo-token')
  await expect(page.getByRole('heading', { name: 'Your bill' })).toBeVisible()
  await expect(page.getByTestId('public-bill')).toContainText('OP consultation')
  await expect(page.getByTestId('public-bill')).toContainText('₹500.00')
})

test('approvals are phone-sized actions and day-end reconciles a closed counter', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/billing/approvals')
  await expect(page.getByRole('heading', { name: 'Pending approvals' })).toBeVisible()
  const card = page.getByTestId('approval-card')
  await expect(card).toBeVisible()
  await card.getByRole('button', { name: 'Approve' }).click()
  await expect(page.getByText('No approvals waiting.')).toBeVisible()

  await page.goto('/billing/day-end?branch=a1111111-0000-4000-8000-000000000001')
  await expect(page.getByRole('heading', { name: 'Day end' })).toBeVisible()
  await expect(page.getByTestId('session-status')).toHaveText('closed')
  await page.getByRole('button', { name: 'Reconcile' }).click()
  await expect(page.getByTestId('session-status')).toHaveText('reconciled')
})
