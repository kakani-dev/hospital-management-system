import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { signIn } from './helpers'

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']

async function seriousViolations(page: import('@playwright/test').Page) {
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map((v) => `${v.id}: ${v.help} (${v.nodes.length} nodes)`)
}

test.describe('accessibility smoke (axe, WCAG 2.1 AA)', () => {
  test('login page has no serious/critical violations', async ({ page }) => {
    await page.goto('/login')
    expect(await seriousViolations(page)).toEqual([])
  })

  test('dashboard has no serious/critical violations', async ({ page }) => {
    await signIn(page)
    expect(await seriousViolations(page)).toEqual([])
  })

  test('patients page has no serious/critical violations', async ({ page }) => {
    await signIn(page)
    await page.goto('/patients')
    await expect(page.getByTestId('patients-empty')).toBeVisible()
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
