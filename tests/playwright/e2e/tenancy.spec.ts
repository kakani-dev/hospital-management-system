import { expect, test } from '@playwright/test'
import { ids, resetActiveContext, signIn, tenantNames, users } from './helpers'

test.describe.configure({ mode: 'serial' })

test.describe('tenant and branch switching', () => {
  test.beforeEach(async () => {
    await resetActiveContext(users.consultant)
    await resetActiveContext(users.alphaAdmin)
  })

  test('consultant switches hospital; data, token and context follow the server-side choice', async ({ page }) => {
    await signIn(page, users.consultant)
    const hospital = page.getByLabel('Hospital')
    await expect(hospital).toHaveValue(ids.alpha)
    await expect(page.getByTestId('dashboard-tenant')).toHaveText(tenantNames.alpha)

    await page.getByRole('link', { name: 'Patients' }).click()
    await expect(page.getByTestId('patient-row').first()).toBeVisible()
    await expect(page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Beta' })).toHaveCount(0)

    await hospital.selectOption(ids.beta)
    await expect(hospital).toHaveValue(ids.beta)
    await expect(page.getByTestId('patient-row').filter({ hasText: 'BET-0001' })).toBeVisible()
    await expect(page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' })).toHaveCount(0)

    // Persisted server-side: survives a full reload (new token from the hook carries Beta).
    await page.reload()
    await expect(page.getByLabel('Hospital')).toHaveValue(ids.beta)
    await expect(page.getByTestId('patient-row').filter({ hasText: 'BET-0001' })).toBeVisible()

    await page.getByLabel('Hospital').selectOption(ids.alpha)
    await expect(page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Beta' })).toHaveCount(0)
  })

  test('admin narrows to a branch and back to all branches', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    const branch = page.getByLabel('Branch', { exact: true })
    await expect(branch.locator('option')).toHaveText(['All my branches', 'Alpha East Clinic', 'Alpha Main Campus'])
    await branch.selectOption({ label: 'Alpha East Clinic' })
    await expect(page.getByTestId('dashboard-branch')).toHaveText('Alpha East Clinic')
    await page.reload()
    await expect(page.getByLabel('Branch', { exact: true })).toHaveValue(ids.alphaEast)
    await page.getByLabel('Branch', { exact: true }).selectOption({ label: 'All my branches' })
    await expect(page.getByTestId('dashboard-branch')).toHaveText('All my branches')
  })

  test('branch-scoped receptionist only sees her branch', async ({ page }) => {
    await signIn(page, users.alphaReception)
    await expect(page.getByLabel('Branch', { exact: true }).locator('option')).toHaveText(['Alpha Main Campus'])
    await expect(page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Members' })).toHaveCount(0)
  })
})
