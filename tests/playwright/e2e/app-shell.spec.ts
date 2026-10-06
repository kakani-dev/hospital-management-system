import { expect, test } from '@playwright/test'
import { demoUser, signIn } from './helpers'

test.describe('app shell', () => {
  test('loads and redirects unauthenticated users to login', async ({ page }) => {
    await page.goto('/')
    await expect(page).toHaveURL(/\/login$/)
    await expect(page).toHaveTitle('HMS')
    await expect(page.getByRole('heading', { name: 'Sign in to HMS' })).toBeVisible()
  })

  test('protected deep link redirects to login', async ({ page }) => {
    await page.goto('/patients')
    await expect(page).toHaveURL(/\/login$/)
  })

  test('login form validates input before signing in', async ({ page }) => {
    await page.goto('/login')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page.getByText('Enter a valid email address')).toBeVisible()
    await expect(page.getByText('Password must be at least 8 characters')).toBeVisible()
    await expect(page.getByLabel('Email')).toHaveAttribute('aria-invalid', 'true')

    await page.getByLabel('Email').fill('not-an-email')
    await page.getByLabel('Password').fill('short')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page).toHaveURL(/\/login$/)
  })

  test('signs in, shows tenant context and navigates', async ({ page }) => {
    await signIn(page)
    await expect(page.getByTestId('tenant-name')).toHaveText('Demo Alpha Hospital (synthetic)')
    await expect(page.getByText(demoUser.email)).toBeVisible()

    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Patients' }).click()
    await expect(page).toHaveURL(/\/patients$/)
    await expect(page.getByRole('heading', { name: 'Patients' })).toBeVisible()
    await expect(page.getByRole('link', { name: 'Patients' })).toHaveAttribute('aria-current', 'page')

    await page.getByRole('link', { name: 'Dashboard' }).click()
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  })

  test('branch switcher only offers branches from the session memberships', async ({ page }) => {
    await signIn(page)
    const branch = page.getByLabel('Branch')
    await expect(branch.locator('option')).toHaveText(['Alpha Main Campus', 'Alpha East Clinic'])
    await branch.selectOption({ label: 'Alpha East Clinic' })
    await page.getByRole('link', { name: 'Patients' }).click()
    await page.reload()
    await expect(page.getByLabel('Branch')).toHaveValue('a1111111-0000-4000-8000-000000000002')
  })

  test('patients page degrades gracefully when the API is unavailable or unauthenticated', async ({ page }) => {
    await signIn(page)
    await page.goto('/patients')
    await expect(page.getByRole('status').filter({ hasText: /unavailable|sign in with a real account/i })).toBeVisible()
    await expect(page.getByTestId('patients-empty')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Register patient' })).toBeDisabled()
  })

  test('sign out clears the session', async ({ page }) => {
    await signIn(page)
    await page.getByRole('button', { name: 'Sign out' }).click()
    await expect(page).toHaveURL(/\/login$/)
    await page.goto('/')
    await expect(page).toHaveURL(/\/login$/)
  })

  test('unknown routes show not-found inside the shell', async ({ page }) => {
    await signIn(page)
    await page.goto('/does-not-exist')
    await expect(page.getByRole('heading', { name: 'Page not found' })).toBeVisible()
  })

  test('@responsive layout works on a mobile viewport', async ({ page }) => {
    await signIn(page)
    await expect(page.getByRole('navigation', { name: 'Primary' })).toBeVisible()
    await expect(page.getByTestId('tenant-context')).toBeVisible()
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    expect(overflow).toBeLessThanOrEqual(1)
  })
})
