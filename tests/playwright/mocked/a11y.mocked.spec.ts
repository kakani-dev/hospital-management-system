import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { MockBackend, addDays, branchInstant, branchToday, ids, patientIds, practitionerIds, signIn } from './mock-backend'

/**
 * Fast axe pass over the phase 2 screens and their drawers/dialogs in both themes (the full-stack
 * a11y.spec.ts covers the same pages against the real API).
 */
const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']

async function seriousViolations(page: Page) {
  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze()
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map((v) => `${v.id}: ${v.help} (${v.nodes.map((n) => `${n.target.join(' ')} :: ${n.failureSummary ?? ''}`).join(' | ')})`)
}

for (const theme of ['light', 'dark'] as const) {
  test.describe(`axe, ${theme} theme`, () => {
    let backend: MockBackend
    test.beforeEach(async ({ context }) => {
      backend = new MockBackend()
      await backend.install(context)
      await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    })

    test('dashboard with stat cards', async ({ page }) => {
      await signIn(page, 'admin@alpha.example')
      await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
      await expect(page.getByTestId('stat-appointments')).toHaveText('1')
      expect(await seriousViolations(page)).toEqual([])
    })

    test('calendar with reschedule drawer and no-show dialog', async ({ page }) => {
      const yesterday = addDays(branchToday(), -1)
      backend.bookDirectly({ branchId: ids.alphaMain, practitionerId: practitionerIds.rao, patientId: patientIds.ravi, startsAt: branchInstant(yesterday, '10:00'), endsAt: branchInstant(yesterday, '10:15') })
      await signIn(page, 'reception@alpha.example')
      await page.goto(`/appointments?branch=${ids.alphaMain}&date=${yesterday}`)
      await page.getByTestId('appointment').getByRole('button', { name: 'Mark no-show' }).click()
      await expect(page.getByRole('alertdialog')).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.getByRole('alertdialog').getByRole('button', { name: 'Cancel' }).click()
      await page.getByTestId('appointment').getByRole('button', { name: 'Reschedule' }).click()
      await expect(page.getByTestId('reschedule-drawer').getByTestId('slot-list')).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
    })

    test('practitioners, working hours, hospital settings and the branch drawer', async ({ page }) => {
      await signIn(page, 'admin@alpha.example')
      await page.goto('/admin/practitioners')
      await expect(page.getByTestId('practitioner-row').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.getByRole('button', { name: 'Edit Dr. Rao (synthetic)' }).click()
      await expect(page.getByTestId('practitioner-drawer')).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.goto(`/admin/working-hours?branch=${ids.alphaMain}`)
      await expect(page.getByTestId('schedule-row').first()).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/admin/hospital')
      await expect(page.getByLabel('Hospital time zone')).toHaveValue('Asia/Kolkata')
      expect(await seriousViolations(page)).toEqual([])
      await page.goto('/admin/branches')
      await page.getByRole('button', { name: 'Edit Alpha East Clinic' }).click()
      await expect(page.getByTestId('branch-drawer')).toBeVisible()
      expect(await seriousViolations(page)).toEqual([])
    })
  })
}
