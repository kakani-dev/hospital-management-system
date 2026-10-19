import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { signIn } from './helpers'

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']
const THEME_STORAGE_KEY = 'hms.theme'

async function seriousViolations(page: Page) {
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    // Selectors and axe's summary make a failure actionable without re-running locally.
    .map((v) => `${v.id}: ${v.help} (${v.nodes.length} nodes: ${v.nodes.map((n) => `${n.target.join(' ')} :: ${n.failureSummary ?? ''}`).join(' | ')})`)
}

// Every check runs in both Tailux themes: the stored preference is applied before first paint.
for (const theme of ['light', 'dark'] as const) {
  test.describe(`accessibility smoke (axe, WCAG 2.1 AA), ${theme} theme`, () => {
    test.beforeEach(async ({ page }) => {
      await page.addInitScript(
        ([key, themeMode]) => window.localStorage.setItem(key, JSON.stringify({ themeMode, cardSkin: 'shadow' })),
        [THEME_STORAGE_KEY, theme] as const,
      )
    })

    const expectTheme = (page: Page) =>
      theme === 'dark' ? expect(page.locator('html')).toHaveClass(/\bdark\b/) : expect(page.locator('html')).not.toHaveClass(/\bdark\b/)

    test('login page', async ({ page }) => {
      await page.goto('/login')
      await expectTheme(page)
      expect(await seriousViolations(page)).toEqual([])
    })

    test('dashboard', async ({ page }) => {
      await signIn(page)
      await expectTheme(page)
      await expect(page.getByTestId('stat-registered')).toHaveText(/^\d+$/)
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

    test('appointments calendar and OPD queue', async ({ page }) => {
      await signIn(page)
      await page.goto('/appointments')
      await expect(page.getByTestId('calendar-day').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/queue')
      await expect(page.getByRole('heading', { name: /queue/i }).first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
    })

    test('admin pages', async ({ page }) => {
      await signIn(page)
      await page.goto('/admin/branches')
      await expect(page.getByTestId('branch-row').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.getByTestId('branch-row').first().getByRole('button', { name: /^Edit / }).click()
      await expect(page.getByTestId('branch-drawer')).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.keyboard.press('Escape')
      await page.goto('/admin/members')
      await expect(page.getByTestId('member-row').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/admin/practitioners')
      await expect(page.getByTestId('practitioner-row').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/admin/working-hours')
      await expect(page.getByRole('form', { name: 'Add working hours' })).toBeVisible()
      // The submit button enables once the branch zone is known; let its colour transition finish.
      await expect(page.getByRole('button', { name: 'Add hours' })).toBeEnabled()
      await page.waitForTimeout(300)
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/admin/hospital')
      await expect(page.getByLabel('Hospital time zone')).not.toHaveValue('')
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
}
