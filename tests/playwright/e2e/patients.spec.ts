import { expect, test } from '@playwright/test'
import { signIn, unique, users } from './helpers'

test.describe('patient registration', () => {
  test('receptionist registers a patient; duplicate MRN is rejected; other tenant cannot see it', async ({ page, browser }) => {
    const mrn = unique('E2E').toUpperCase()
    await signIn(page, users.alphaReception)
    await page.getByRole('link', { name: 'Patients' }).click()
    await page.getByRole('link', { name: 'Register patient' }).click()

    await page.getByLabel('MRN').fill(mrn)
    await page.getByLabel('First name').fill('Playwright')
    await page.getByLabel('Last name').fill('Synthetic-E2E')
    await page.getByLabel('Date of birth').fill('1991-02-03')
    await page.getByLabel('Sex').selectOption('female')
    await expect(page.getByLabel('Registered branch')).toHaveValue('a1111111-0000-4000-8000-000000000001')
    await page.getByRole('button', { name: 'Register patient' }).click()

    await expect(page.getByText(`Patient ${mrn} registered.`)).toBeVisible()
    await page.getByLabel('Search patients').fill(mrn)
    await expect(page.getByTestId('patient-row').filter({ hasText: mrn })).toBeVisible()

    // Duplicate MRN in the same tenant -> 409 mapped to a field error.
    await page.getByRole('link', { name: 'Register patient' }).click()
    await page.getByLabel('MRN').fill(mrn)
    await page.getByLabel('First name').fill('Dup')
    await page.getByLabel('Last name').fill('Synthetic-E2E')
    await page.getByRole('button', { name: 'Register patient' }).click()
    await expect(page.getByText('This MRN already exists in this hospital')).toBeVisible()

    // Beta admin (separate browser context) cannot find it.
    const other = await browser.newContext()
    const betaPage = await other.newPage()
    await signIn(betaPage, users.betaAdmin)
    await betaPage.goto('/patients')
    await betaPage.getByLabel('Search patients').fill(mrn)
    await expect(betaPage.getByTestId('patients-empty')).toBeVisible()
    await other.close()
  })

  test('client-side validation blocks bad input', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    await page.goto('/patients/new')
    await page.getByLabel('MRN').fill('has spaces')
    await page.getByRole('button', { name: 'Register patient' }).click()
    await expect(page.getByText(/MRN is required: 1-32 letters/)).toBeVisible()
    await expect(page.getByText('First name is required')).toBeVisible()
  })

  test('lab technician cannot read the patient registry', async ({ page }) => {
    await signIn(page, users.alphaLab)
    await page.goto('/patients')
    await expect(page.getByText('does not include access to the patient registry')).toBeVisible()
    await expect(page.getByRole('link', { name: 'Register patient' })).toHaveCount(0)
  })
})
