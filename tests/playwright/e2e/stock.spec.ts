import { expect, test, type Page } from '@playwright/test'
import { ids, signIn, unique, users } from './helpers'

/**
 * #74 Stock screen against the real API (web + microservices + Postgres/RLS):
 * add a store -> add an item with a reorder level at that store -> post opening stock ->
 * Stock on hand shows the batch, quantity and a low-stock flag. A role without stock rights
 * never sees the screen. Every name is fresh (Zz-) and dates are relative to today.
 */

/** Options may carry a code suffix, e.g. "Name (STR-0001)"; pick by the visible name. */
async function pick(page: Page, label: string, name: string) {
  const select = page.getByRole('main').getByLabel(label)
  const value = await select.locator('option', { hasText: name }).first().getAttribute('value')
  expect(value, `${label} has an option for ${name}`).toBeTruthy()
  await select.selectOption(value!)
}

const isoInDays = (days: number) => new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10)

test('admin adds a store and item, posts opening stock and sees it on hand with a low-stock flag', async ({ page }) => {
  const storeName = `Zz-E2E ${unique('Store')}`
  const brand = `Zz-E2E ${unique('Tab')}`
  const batch = unique('B').toUpperCase()

  await signIn(page, users.alphaAdmin)
  await page.goto('/stock')
  await expect(page.getByRole('heading', { name: 'Stock', level: 1 })).toBeVisible()

  // Let the items, stores and branches queries settle so a late load cannot remount a half-filled form.
  await page.waitForLoadState('networkidle')
  await page.getByRole('tab', { name: 'Stores' }).click()
  await expect(page.getByRole('main').getByLabel('Branch').locator(`option[value="${ids.alphaMain}"]`)).toHaveCount(1)
  await page.getByRole('main').getByLabel('Branch').selectOption(ids.alphaMain)
  await page.getByRole('main').getByLabel('Store name').fill(storeName)
  await page.getByRole('main').getByLabel('Store kind').selectOption('op_pharmacy')
  await page.getByRole('main').getByLabel('Drug licence number').fill(`DL-${unique('E2E')}`)
  await page.getByRole('main').getByLabel('Licence valid until').fill(isoInDays(730))
  await expect(page.getByRole('main').getByLabel('Store name')).toHaveValue(storeName)
  await page.getByRole('button', { name: 'Save store' }).click()
  await expect(page.getByText(/Saved\. The store code is/)).toBeVisible()
  await expect(page.getByTestId('stock-store-row').filter({ hasText: storeName })).toHaveCount(1)

  await page.getByRole('tab', { name: 'Items' }).click()
  await page.getByRole('main').getByLabel('Kind').selectOption('drug')
  await page.getByRole('main').getByLabel('Brand name').fill(brand)
  await page.getByRole('main').getByLabel('Generic name').fill('Paracetamol')
  await page.getByRole('main').getByLabel('Strength').fill('500 mg')
  await page.getByRole('main').getByLabel('Form').fill('tablet')
  await page.getByRole('main').getByLabel('Maker').fill('Zz Synthetic Pharma')
  await page.getByRole('main').getByLabel('HSN').fill('30049099')
  await page.getByRole('main').getByLabel('GST').selectOption('1200')
  await page.getByRole('main').getByLabel('Base unit').selectOption('TAB')
  await pick(page, 'Reorder at store', storeName)
  await page.getByRole('main').getByLabel('Reorder when quantity falls below').fill('10')
  await page.getByRole('button', { name: 'Save item' }).click()
  await expect(page.getByText(/Saved\. The item code is/)).toBeVisible()
  await expect(page.getByTestId('stock-item-row').filter({ hasText: brand })).toHaveCount(1)

  // Client-side guard: an expiry-less line never reaches the API.
  await page.getByRole('tab', { name: 'Opening stock' }).click()
  await pick(page, 'Store', storeName)
  await pick(page, 'Item', brand)
  await page.getByRole('main').getByLabel('Batch number on the pack').fill(batch)
  await page.getByRole('button', { name: 'Save opening stock' }).click()
  await expect(page.getByText(/enter the batch, expiry, prices, and a quantity/)).toBeVisible()

  await page.getByRole('main').getByLabel('Expiry').fill(isoInDays(540))
  await page.getByRole('main').getByLabel('MRP (rupees)').fill('25')
  await page.getByRole('main').getByLabel('Purchase rate (rupees)').fill('12.50')
  await page.getByRole('main').getByLabel('Quantity').fill('6')
  await page.getByRole('button', { name: 'Save opening stock' }).click()
  await expect(page.getByText(/Saved\. Opening stock .* records you as the approver\./)).toBeVisible()

  await page.getByRole('tab', { name: 'Stock on hand' }).click()
  await pick(page, 'Store', storeName)
  const row = page.locator(`[data-testid="stock-row"][data-batch="${batch}"]`)
  await expect(row).toHaveCount(1)
  await expect(row).toContainText(brand)
  await expect(row).toContainText('6 TAB')
  await expect(row.getByTestId('low-stock')).toContainText('reorder 10')

  await page.getByRole('main').getByLabel('Below reorder level').check()
  await expect(row).toHaveCount(1)
})

test('a role without stock rights has no Stock entry and is kept off the screen', async ({ page }) => {
  await signIn(page, users.alphaReception)
  await expect(page.getByRole('link', { name: 'Stock', exact: true })).toHaveCount(0)
  await page.goto('/stock')
  await expect(page.getByRole('heading', { name: 'Stock', level: 1 })).toHaveCount(0)
  await expect(page.getByRole('tab', { name: 'Opening stock' })).toHaveCount(0)
})
