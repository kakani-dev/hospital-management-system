import { expect, type Page } from '@playwright/test'

/** Synthetic credentials: the Sprint 0 login placeholder only validates format. */
export const demoUser = { email: 'admin@alpha.example', password: 'synthetic-password' }

export async function signIn(page: Page) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(demoUser.email)
  await page.getByLabel('Password').fill(demoUser.password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
}
