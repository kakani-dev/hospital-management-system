import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { signIn } from './helpers'

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']

async function seriousViolations(page: Page) {
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    // Selectors and axe's summary make a failure actionable without re-running locally.
    .map((v) => `${v.id}: ${v.help} (${v.nodes.length} nodes: ${v.nodes.map((n) => `${n.target.join(' ')} :: ${n.failureSummary ?? ''}`).join(' | ')})`)
}

test.describe('accessibility smoke (axe, WCAG 2.1 AA)', () => {
  test('login page', async ({ page }) => {
    await page.goto('/login')
    expect(await seriousViolations(page)).toEqual([])
  })

  test('dashboard', async ({ page }) => {
    await signIn(page)
    expect(await seriousViolations(page)).toEqual([])
  })

  test('patients list and registration form', async ({ page }) => {
    await signIn(page)
    await page.goto('/patients')
    await expect(page.getByTestId('patient-row').first()).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto('/patients/new')
    await expect(page.getByRole('heading', { name: 'Register patient' })).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
  })

  test('admin pages', async ({ page }) => {
    await signIn(page)
    await page.goto('/admin/branches')
    await expect(page.getByTestId('branch-row').first()).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await page.goto('/admin/members')
    await expect(page.getByTestId('member-row').first()).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
  })

  test('skip link moves focus to main content', async ({ page }) => {
    await signIn(page)
    await page.keyboard.press('Tab')
    const skip = page.getByRole('link', { name: 'Skip to main content' })
    await expect(skip).toBeFocused()
    await page.keyboard.press('Enter')
    await expect(page.locator('#main-content')).toBeFocused()
  })
})
