import { expect, test } from '@playwright/test'
import { bearer, signIn, tokenFor, unique, users } from './helpers'

/**
 * #75 / REG-041 Price list against the real API: a new service shows and keeps its category's GST
 * default (read from the API, not hard-coded), then is deactivated, hidden, shown with
 * "Show inactive" and activated again. Every name is a fresh Zz- name.
 */

interface CategoryDefault { category: string; rateBp: number; isExempt: boolean; sacHsnCode: string; codePrefix: string }

const taxText = (d: CategoryDefault) =>
  d.isExempt || d.rateBp === 0 ? 'Healthcare service, GST exempt' : `Taxable service ${d.rateBp % 100 === 0 ? d.rateBp / 100 : (d.rateBp / 100).toFixed(2)}%`

test('a new service takes its category GST default, then is deactivated and brought back', async ({ page, request }) => {
  const admin = bearer(await tokenFor(request, users.alphaAdmin))
  const defaults = (await (await request.get('/api/v1/service-items/category-defaults', { headers: admin })).json()) as CategoryDefault[]
  expect(defaults.length).toBeGreaterThan(1)

  await signIn(page, users.alphaAdmin)
  await page.goto('/admin/price-list')
  await expect(page.getByRole('heading', { name: 'Price list', level: 1 })).toBeVisible()
  const form = page.getByRole('form', { name: 'Add service' })

  // Every category shows its own default before saving.
  for (const d of defaults) {
    await form.getByLabel('Category').selectOption(d.category)
    await expect(form.getByTestId('service-tax')).toContainText(taxText(d))
    await expect(form.getByTestId('service-tax')).toContainText(`SAC ${d.sacHsnCode}`)
  }

  const chosen = defaults[defaults.length - 1]!
  const name = `Zz-E2E ${unique('Svc')}`
  await form.getByLabel('Category').selectOption(chosen.category)
  await form.getByLabel('Name').fill(name)
  await form.getByRole('button', { name: 'Add service' }).click()
  // Adding opens the rate panel for the new service; close it to get back to the list.
  const panel = page.getByRole('dialog', { name })
  await expect(panel).toBeVisible()
  await panel.getByRole('button', { name: `Close ${name}` }).click()
  await expect(panel).toHaveCount(0)

  const search = page.getByLabel('Search services')
  await search.fill(name)
  const row = page.getByTestId('service-item-row').filter({ hasText: name })
  await expect(row).toHaveCount(1)
  await expect(row).toContainText(taxText(chosen))
  await expect(row).toContainText('Active')
  expect(await row.getAttribute('data-code')).toMatch(new RegExp(`^${chosen.codePrefix}-`))

  await page.getByRole('button', { name: `Deactivate ${name}` }).click()
  await expect(page.getByText(`${name} is now inactive.`)).toBeVisible()
  await expect(row).toHaveCount(0)

  await page.getByLabel('Show inactive').check()
  await expect(row).toHaveCount(1)
  await expect(row).toContainText('Inactive')

  await page.getByRole('button', { name: `Activate ${name}` }).click()
  await expect(page.getByText(`${name} is active again.`)).toBeVisible()
  await page.getByLabel('Show inactive').uncheck()
  await expect(row).toHaveCount(1)
  await expect(row).toContainText('Active')
})
