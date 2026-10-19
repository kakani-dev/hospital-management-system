import { expect, test } from '@playwright/test'
import { signIn, tenantNames, users } from './helpers'

test.describe('app shell and authentication', () => {
  test('redirects unauthenticated users to login', async ({ page }) => {
    await page.goto('/')
    await expect(page).toHaveURL(/\/login$/)
    await expect(page).toHaveTitle('HMS')
    await expect(page.getByRole('heading', { name: 'Sign in to HMS' })).toBeVisible()
  })

  test('protected deep link redirects to login and back after sign-in', async ({ page }) => {
    await page.goto('/patients')
    await expect(page).toHaveURL(/\/login$/)
    await page.getByLabel('Email').fill(users.alphaAdmin)
    await page.getByLabel('Password').fill(process.env.E2E_PASSWORD ?? 'synthetic-demo-pass')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page).toHaveURL(/\/patients$/)
    await expect(page.getByRole('heading', { name: 'Patients' })).toBeVisible()
  })

  test('login form validates input', async ({ page }) => {
    await page.goto('/login')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page.getByText('Enter a valid email address')).toBeVisible()
    await expect(page.getByText('Password must be at least 8 characters')).toBeVisible()
    await expect(page.getByLabel('Email')).toHaveAttribute('aria-invalid', 'true')
  })

  test('wrong password is rejected by the auth server', async ({ page }) => {
    await page.goto('/login')
    await page.getByLabel('Email').fill(users.alphaAdmin)
    await page.getByLabel('Password').fill('definitely-wrong')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page.getByRole('alert').filter({ hasText: 'Invalid login credentials' })).toBeVisible()
    await expect(page).toHaveURL(/\/login$/)
  })

  test('signs in with a real token, shows server-resolved context and navigates', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    await expect(page.getByTestId('dashboard-tenant')).toHaveText(tenantNames.alpha)
    await expect(page.getByTestId('active-roles')).toHaveText('tenant admin')
    await expect(page.getByTestId('api-status')).toHaveText('Healthy')

    const nav = page.getByRole('navigation', { name: 'Primary' })
    await nav.getByRole('link', { name: 'Patients' }).click()
    await expect(page.getByRole('heading', { name: 'Patients' })).toBeVisible()
    await expect(nav.getByRole('link', { name: 'Patients' })).toHaveAttribute('aria-current', 'page')
    await expect(nav.getByRole('link', { name: 'Branches' })).toBeVisible()
    await expect(nav.getByRole('link', { name: 'Members' })).toBeVisible()
  })

  test('session survives reload; sign out clears it', async ({ page }) => {
    await signIn(page)
    await page.reload()
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
    await page.getByRole('button', { name: 'Sign out' }).click()
    await expect(page).toHaveURL(/\/login$/)
    await page.goto('/')
    await expect(page).toHaveURL(/\/login$/)
  })

  test('user without memberships gets no tenant and no data', async ({ page }) => {
    await signIn(page, users.outsider)
    await expect(page.getByTestId('tenant-name')).toHaveText('No hospital memberships')
    await page.goto('/patients')
    await expect(page.getByText('does not include access to the patient registry')).toBeVisible()
    await expect(page.getByTestId('patient-row')).toHaveCount(0)
  })

  test('unknown routes show not-found inside the shell', async ({ page }) => {
    await signIn(page)
    await page.goto('/does-not-exist')
    await expect(page.getByRole('heading', { name: 'Page not found' })).toBeVisible()
  })

  test('@responsive layout works on a mobile viewport', async ({ page }) => {
    await signIn(page)
    // Tailux Sideblock: below xl the sidebar is off-canvas behind the header's toggle.
    const toggle = page.getByRole('button', { name: 'Toggle navigation' })
    if (await toggle.isVisible()) {
      await toggle.click()
      await expect(toggle).toHaveAttribute('aria-expanded', 'true')
      await expect(page.getByRole('navigation', { name: 'Primary' })).toBeVisible()
      await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Patients', exact: true }).click()
      await expect(page).toHaveURL(/\/patients$/)
    } else {
      await expect(page.getByRole('navigation', { name: 'Primary' })).toBeVisible()
    }
    await expect(page.getByTestId('tenant-context')).toBeVisible()
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    expect(overflow).toBeLessThanOrEqual(1)
  })
})
