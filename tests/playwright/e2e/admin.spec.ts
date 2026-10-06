import { expect, test } from '@playwright/test'
import { createSyntheticUser, signIn, unique, users } from './helpers'

test.describe('tenant admin', () => {
  test('creates and deactivates a branch; duplicate code is rejected', async ({ page }) => {
    const code = unique('br').toLowerCase()
    await signIn(page, users.alphaAdmin)
    await page.getByRole('link', { name: 'Branches' }).click()
    await expect(page.getByTestId('branch-row').filter({ hasText: 'Alpha Main Campus' })).toBeVisible()
    await expect(page.getByTestId('branch-row').filter({ hasText: 'Beta Central' })).toHaveCount(0)

    await page.getByLabel('Code').fill(code)
    await page.getByLabel('Branch name').fill(`E2E ${code}`)
    await page.getByRole('button', { name: 'Add branch' }).click()
    const row = page.getByTestId('branch-row').filter({ hasText: code })
    await expect(row).toContainText('Active')

    await page.getByRole('button', { name: `Deactivate E2E ${code}` }).click()
    await expect(row).toContainText('Inactive')

    await page.getByLabel('Code').fill(code)
    await page.getByLabel('Branch name').fill('Again')
    await page.getByRole('button', { name: 'Add branch' }).click()
    await expect(page.getByText('A branch with this code already exists')).toBeVisible()
  })

  test('adds a member with branch scope, then suspends them; unknown email is reported', async ({ page }) => {
    const email = await createSyntheticUser('newnurse')
    await signIn(page, users.alphaAdmin)
    await page.getByRole('link', { name: 'Members' }).click()
    await expect(page.getByTestId('member-row').filter({ hasText: users.alphaReception })).toBeVisible()
    await expect(page.getByTestId('member-row').filter({ hasText: users.betaAdmin })).toHaveCount(0)

    await page.getByLabel('Email').fill(email)
    await page.getByLabel('Role', { exact: true }).selectOption('nurse')
    await page.getByLabel('Branch scope').selectOption({ label: 'Alpha East Clinic' })
    await page.getByRole('button', { name: 'Add member' }).click()
    const row = page.getByTestId('member-row').filter({ hasText: email })
    await expect(row).toContainText('Alpha East Clinic')
    await expect(row).toContainText('active')

    await page.getByRole('button', { name: `Suspend ${email}` }).click()
    await expect(row).toContainText('suspended')

    await page.getByLabel('Email').fill('nobody-here@synthetic.example')
    await page.getByRole('button', { name: 'Add member' }).click()
    await expect(page.getByText('No user with this email has signed up yet')).toBeVisible()
  })

  test('non-admin cannot open admin pages', async ({ page }) => {
    await signIn(page, users.betaDoctor)
    await page.goto('/admin/members')
    await expect(page.getByText('Only tenant admins can open this page.')).toBeVisible()
  })
})
