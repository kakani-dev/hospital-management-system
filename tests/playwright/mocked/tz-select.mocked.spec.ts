import AxeBuilder from '@axe-core/playwright'
import { devices, expect, test, type Page, type TestInfo } from '@playwright/test'
import { MockBackend, OPERATOR_EMAIL, PASSWORD, signIn } from './mock-backend'

/**
 * Time zone fields (Create hospital drawer, public Register your hospital, branch override) are a
 * searchable Tailux/Headless UI combobox over Intl.supportedValuesOf('timeZone'). The old input +
 * <datalist> rendered as an EMPTY dropdown on mobile Chrome, so these run at phone size with touch.
 * TZ_SHOTS_DIR=<dir> also saves the mobile screenshots (light + dark) there.
 */
let backend: MockBackend

const { defaultBrowserType: _ignored, ...pixel } = devices['Pixel 7']
test.use({ ...pixel, timezoneId: 'Asia/Kolkata' })

test.beforeEach(async ({ context }) => {
  backend = new MockBackend()
  await backend.install(context)
})

async function shot(page: Page, info: TestInfo, name: string) {
  const dir = process.env.TZ_SHOTS_DIR
  const body = await page.screenshot({ ...(dir ? { path: `${dir}/${name}.png` } : {}) })
  await info.attach(name, { body, contentType: 'image/png' })
}

async function seriousViolations(page: Page) {
  await page.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => undefined))))
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()
  return results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)
}

/** Tapping the field opens a non-empty, on-screen list (the bug: an empty native dropdown). */
async function expectOpenList(page: Page, field: ReturnType<Page['getByLabel']>) {
  await field.tap()
  const list = page.getByRole('listbox')
  await expect(list).toBeVisible()
  expect(await list.getByRole('option').count()).toBeGreaterThan(300)
  const box = (await list.boundingBox())!
  const viewport = page.viewportSize()!
  expect(box.x).toBeGreaterThanOrEqual(0)
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width + 0.5)
  expect(box.height).toBeGreaterThan(100)
  return list
}

test('no datalist anywhere; public registration picks a zone by tapping a searched option', async ({ page }) => {
  await page.goto('/register-hospital')
  const zone = page.getByRole('combobox', { name: 'Hospital time zone' })
  await expect(zone).toHaveValue('Asia/Kolkata') // browser zone (context timezoneId)
  expect(await page.locator('datalist').count()).toBe(0)
  await expectOpenList(page, zone)
  await zone.fill('dubai')
  await expect(page.getByRole('option')).toHaveCount(1)
  await page.getByRole('option', { name: /^Asia\/Dubai/ }).tap()
  await expect(zone).toHaveValue('Asia/Dubai')
  await expect(page.getByRole('listbox')).toBeHidden()
  await page.getByLabel('Hospital name').fill('Synthetic Palm Clinic')
  await page.getByLabel('City').fill('Kochi')
  await page.getByLabel('Your name').fill('Palm Synthetic')
  await page.getByLabel('Work email').fill('palm@palm.example')
  await page.getByLabel('Phone').fill('+91 484 555 0101')
  await page.getByRole('button', { name: 'Send request' }).tap()
  await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible()
  expect(backend.signups.find((s) => s.contactEmail === 'palm@palm.example')?.timeZone).toBe('Asia/Dubai')
})

test.describe('browser in another listed zone', () => {
  test.use({ timezoneId: 'Europe/Berlin' })
  test('the zone defaults to the browser zone', async ({ page }) => {
    await page.goto('/register-hospital')
    await expect(page.getByRole('combobox', { name: 'Hospital time zone' })).toHaveValue('Europe/Berlin')
  })
})

test('Create hospital drawer: the zone list opens inside the drawer on a phone and the chosen zone is sent', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email').fill(OPERATOR_EMAIL)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).tap()
  await page.getByRole('heading', { name: 'Hospitals' }).first().waitFor()
  await page.getByRole('button', { name: 'Create hospital' }).tap()
  const drawer = page.getByTestId('create-tenant-drawer')
  const zone = drawer.getByRole('combobox', { name: 'Hospital time zone' })
  await expect(zone).toHaveValue('Asia/Kolkata')
  await drawer.getByLabel('Hospital name').fill('Synthetic Fern Hospital')
  await drawer.getByRole('button', { name: 'Show list' }).tap()
  const list = drawer.getByRole('listbox')
  await expect(list).toBeVisible()
  expect(await list.getByRole('option').count()).toBeGreaterThan(300)
  await zone.fill('new york')
  await drawer.getByRole('option', { name: /^America\/New_York/ }).tap()
  await expect(zone).toHaveValue('America/New_York')
  await drawer.getByLabel('First admin email').fill('fern@fern.example')
  await drawer.getByRole('button', { name: 'Create hospital' }).tap()
  await expect(page.getByTestId('invite-link-url')).toBeVisible()
  expect(backend.platformTenants.find((t) => t.name === 'Synthetic Fern Hospital')?.timeZone).toBe('America/New_York')
})

test('branch override: the add-branch picker opens on a phone; the edit drawer sends the picked zone', async ({ page }) => {
  await signIn(page, 'admin@alpha.example')
  await page.goto('/admin/branches')
  await page.getByLabel(/^Use hospital time zone/).first().uncheck()
  const add = page.getByRole('combobox', { name: 'Time zone' })
  await expect(add).toHaveValue('Asia/Kolkata')
  await expectOpenList(page, add)
  await add.fill('+04:00')
  await page.getByRole('option', { name: /^Asia\/Dubai/ }).tap()
  await expect(add).toHaveValue('Asia/Dubai')

  await page.getByRole('button', { name: 'Edit Alpha East Clinic' }).tap()
  const drawer = page.getByTestId('branch-drawer')
  await drawer.getByLabel(/^Use hospital time zone/).uncheck()
  const zone = drawer.getByRole('combobox', { name: 'Branch time zone' })
  await zone.tap()
  await zone.fill('tokyo')
  await drawer.getByRole('option', { name: /^Asia\/Tokyo/ }).tap()
  await expect(zone).toHaveValue('Asia/Tokyo')
  await drawer.getByRole('button', { name: 'Save branch' }).tap()
  await expect.poll(() => backend.calls.find((c) => c.method === 'PATCH' && c.path.startsWith('/api/v1/branches/'))?.body).toMatchObject({ timezone: 'Asia/Tokyo' })
})

for (const theme of ['light', 'dark'] as const) {
  test(`mobile ${theme}: open zone lists pass axe (register page, Create hospital drawer, branch edit drawer)`, async ({ page, context }, info) => {
    await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    await page.goto('/register-hospital')
    const zone = page.getByRole('combobox', { name: 'Hospital time zone' })
    await expectOpenList(page, zone)
    await zone.fill('asia/k')
    expect(await seriousViolations(page)).toEqual([])
    await shot(page, info, `register-hospital-${theme}`)
    await page.keyboard.press('Escape')

    await page.goto('/login')
    await page.getByLabel('Email').fill(OPERATOR_EMAIL)
    await page.getByLabel('Password').fill(PASSWORD)
    await page.getByRole('button', { name: 'Sign in' }).tap()
    await page.getByRole('heading', { name: 'Hospitals' }).first().waitFor()
    await page.getByRole('button', { name: 'Create hospital' }).tap()
    const drawer = page.getByTestId('create-tenant-drawer')
    await drawer.getByRole('button', { name: 'Show list' }).tap()
    await expect(drawer.getByRole('listbox')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await shot(page, info, `create-hospital-${theme}`)
  })

  test(`mobile ${theme}: branch override picker (add branch + edit drawer)`, async ({ page, context }, info) => {
    await context.addInitScript((themeMode) => window.localStorage.setItem('hms.theme', JSON.stringify({ themeMode, cardSkin: 'shadow' })), theme)
    await signIn(page, 'admin@alpha.example')
    await page.goto('/admin/branches')
    await page.getByLabel(/^Use hospital time zone/).first().uncheck()
    const add = page.getByRole('combobox', { name: 'Time zone' })
    await add.tap()
    await add.fill('europe/')
    await expect(page.getByRole('listbox')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
    await shot(page, info, `branch-override-${theme}`)
    await page.keyboard.press('Escape')
    await page.getByRole('button', { name: 'Edit Alpha East Clinic' }).tap()
    const drawer = page.getByTestId('branch-drawer')
    await drawer.getByLabel(/^Use hospital time zone/).uncheck()
    await drawer.getByRole('combobox', { name: 'Branch time zone' }).tap()
    await expect(drawer.getByRole('listbox')).toBeVisible()
    expect(await seriousViolations(page)).toEqual([])
  })
}
