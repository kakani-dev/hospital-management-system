import { readFile } from 'node:fs/promises'
import { expect, test } from '@playwright/test'
import { MockBackend, ids, signIn } from './mock-backend'

/** Earnings is limited to admin, billing and the read-only accountant. The API is mocked. */
let backend: MockBackend

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

test('receptionist is kept out, and an accountant can read, drill in and export', async ({ page }) => {
  await signIn(page, 'reception@alpha.example')
  await expect(page.getByRole('link', { name: 'Earnings' })).toHaveCount(0)
  await page.goto('/billing/earnings')
  await expect(page.getByTestId('forbidden')).toBeVisible()

  await page.context().clearCookies()
  await page.evaluate(() => {
    sessionStorage.clear()
    localStorage.clear()
  })
  await signIn(page, 'accounts@alpha.example')
  await expect(page.getByRole('link', { name: 'Earnings' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Bills' })).toHaveCount(0)

  await page.goto('/billing/earnings?from=2026-04-01&to=2026-04-30')
  await expect(page.getByTestId('earnings-gross')).toBeVisible()
  await expect(page.getByTestId('earnings-categories')).toBeVisible() // #176
  for (const key of ['consult', 'procedure', 'lab', 'other']) await expect(page.getByTestId(`earnings-category-${key}`)).toBeVisible()
  await expect(page.getByTestId('earnings-insight')).toHaveText('Alpha Main Campus revenue down 12% vs last month')
  await page.getByRole('button', { name: /Alpha Main Campus/ }).click()
  await expect(page).toHaveURL(new RegExp(`branch=${ids.alphaMain}`))

  await page.getByRole('button', { name: 'Accounts' }).click()
  await expect(page.getByTestId('gst-summary')).toBeVisible()
  await expect(page.getByTestId('sales-register')).toBeVisible()
  const [csv, download] = await Promise.all([
    page.waitForResponse((response) => response.url().includes('/earnings/export') && response.url().includes('section=sales')),
    page.waitForEvent('download'),
    page.getByRole('button', { name: 'Sales register CSV' }).click(),
  ])
  expect(csv.headers()['content-type']).toContain('text/csv')
  expect(download.suggestedFilename()).toBe('earnings-sales.csv')
  expect(await readFile(await download.path(), 'utf8')).toContain('Invoice number')
})
