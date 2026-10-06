import { expect, test, type Page } from '@playwright/test'
import { ids, openSecondTab, resetActiveContext, signIn, users } from './helpers'

/**
 * PR #1 review finding M3: the active tenant is per user (not per session), and the SPA never
 * noticed when it changed underneath it, so one tab could show hospital X in the header while
 * listing hospital Y's patients; SIGNED_OUT from another tab left PHI in the query cache.
 *
 * Contract (FIX-PLAN.md, Web, option b): on TOKEN_REFRESHED compare the decoded tenant_id /
 * X-Hms-Tenant with the displayed tenant; on mismatch queryClient.clear() + banner.
 * queryClient.clear() on SIGNED_OUT (any tab) and on tenant switch.
 *
 * The session lives in sessionStorage (per tab), so tab 2 is opened from tab 1 with window.open
 * (openSecondTab), like a user opening a link in a new tab. Both tabs then hold the same refresh
 * token, so tab 2 may be signed out once tab 1 refreshes: that is expected and tolerated here.
 * A signed-out tab 2 with nothing cached still passes the "cache cleared" check. These tests do
 * NOT assert what tab 2 shows after the switch (Beta data is not required immediately); they
 * assert the banner and that nothing cached before the switch survives.
 */

/** Synthetic PHI markers from supabase/seed.sql. */
const ALPHA_PHI = /Synthetic-Alpha|ALP-000\d/
const ANY_PHI = /Synthetic-(Alpha|Beta)|ALP-000\d|BET-000\d|MRN-1001/

/** Web fix: role="alert" data-testid="tenant-switched-banner" (CTO frontend notes). */
const tenantSwitchedBanner = (page: Page) => page.getByTestId('tenant-switched-banner')

interface FiberLike {
  child?: FiberLike | null
  sibling?: FiberLike | null
  memoizedProps?: { client?: unknown } | null
}
interface QueryLike {
  queryKey: unknown
  state: { data?: unknown; dataUpdatedAt?: number }
}
interface CachedQuery {
  key: unknown
  data: unknown
  dataUpdatedAt: number
}
interface QueryClientLike {
  getQueryCache: () => { getAll: () => QueryLike[] }
}

/**
 * Serialises the app's TanStack Query cache (keys + data) by locating the QueryClientProvider in
 * the React tree. The cache is in memory only, so this is the only way to prove that cached PHI
 * is really gone rather than merely not rendered (e.g. hidden behind a /login redirect).
 * Returns null if the provider cannot be found (the test then fails loudly).
 */
async function queryCacheDump(page: Page): Promise<string | null> {
  const queries = await cachedQueries(page)
  return queries === null ? null : JSON.stringify(queries.map(({ key, data }) => ({ key, data })))
}

async function cachedQueries(page: Page): Promise<CachedQuery[] | null> {
  return page.evaluate(() => {
    const root = document.getElementById('root') as (HTMLElement & Record<string, unknown>) | null
    const key = root ? Object.keys(root).find((k) => k.startsWith('__reactContainer$')) : undefined
    if (!root || !key) return null
    const stack: (FiberLike | null | undefined)[] = [root[key] as FiberLike]
    const seen = new Set<FiberLike>()
    while (stack.length > 0) {
      const fiber = stack.pop()
      if (!fiber || seen.has(fiber)) continue
      seen.add(fiber)
      const client = fiber.memoizedProps?.client as QueryClientLike | undefined
      if (client && typeof client.getQueryCache === 'function') {
        return client
          .getQueryCache()
          .getAll()
          .map((q) => ({ key: q.queryKey, data: q.state.data ?? null, dataUpdatedAt: q.state.dataUpdatedAt ?? 0 }))
      }
      stack.push(fiber.child, fiber.sibling)
    }
    return null
  })
}

async function webStorage(page: Page) {
  return page.evaluate(() => ({
    local: Object.fromEntries(Object.entries(localStorage)),
    session: Object.fromEntries(Object.entries(sessionStorage)),
  }))
}

const alphaRows = (page: Page) => page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Alpha' })
const betaRows = (page: Page) => page.getByTestId('patient-row').filter({ hasText: 'Synthetic-Beta' })

test.describe.configure({ mode: 'serial' })

test.describe('M3 tenant switch and sign-out clear cached data across tabs', () => {
  test.beforeEach(async () => {
    await resetActiveContext(users.consultant)
  })

  test.afterAll(async () => {
    // Leave the shared E2E database as other specs expect it.
    await resetActiveContext(users.consultant)
  })

  test('M3_switching_hospital_in_one_tab_clears_the_other_tabs_cache_and_shows_the_tenant_switched_banner', async ({ page: tab1 }) => {
    await signIn(tab1, users.consultant)
    await expect(tab1.getByLabel('Hospital')).toHaveValue(ids.alpha)

    // Tab 2 (opened from tab 1, so it starts signed in) caches Alpha's registry.
    const tab2 = await openSecondTab(tab1, '/patients')
    await expect(alphaRows(tab2).first()).toBeVisible()
    expect(await queryCacheDump(tab2)).toMatch(ALPHA_PHI)
    await expect(tenantSwitchedBanner(tab2)).toHaveCount(0)

    // Switch hospital in tab 1 (server-side context change + token refresh, broadcast to other tabs).
    await tab1.bringToFront()
    const switchedAt = await tab2.evaluate(() => Date.now())
    await tab1.getByLabel('Hospital').selectOption(ids.beta)
    await expect(tab1.getByLabel('Hospital')).toHaveValue(ids.beta)
    await tab1.getByRole('link', { name: 'Patients' }).click()
    await expect(betaRows(tab1).first()).toBeVisible()
    await expect(tab1.locator('main')).not.toContainText(ALPHA_PHI)
    // The tab that made the switch itself gets no "changed elsewhere" banner.
    await expect(tenantSwitchedBanner(tab1)).toHaveCount(0)

    // Tab 2: banner, and nothing cached before the switch survives (no assertion on what it shows next).
    await tab2.bringToFront()
    await expect(tenantSwitchedBanner(tab2)).toBeVisible()
    await expect
      .poll(async () => {
        const queries = await cachedQueries(tab2)
        if (queries === null) return 'QueryClientProvider not found'
        const stale = queries.filter((q) => q.data !== null && q.dataUpdatedAt < switchedAt)
        return stale.length === 0 ? 'cleared' : `stale: ${JSON.stringify(stale.map((q) => q.key))}`
      })
      .toBe('cleared')
  })

  test('M3_signing_out_clears_query_cache_and_web_storage_in_every_tab_and_back_navigation_shows_no_PHI', async ({ page: tab1 }) => {
    await signIn(tab1, users.consultant)
    await tab1.getByRole('link', { name: 'Patients' }).click()
    await expect(alphaRows(tab1).first()).toBeVisible()

    const tab2 = await openSecondTab(tab1, '/patients')
    await expect(alphaRows(tab2).first()).toBeVisible()
    expect(await queryCacheDump(tab2)).toMatch(ALPHA_PHI)

    // Sign out in tab 1 only.
    await tab1.bringToFront()
    await tab1.getByRole('button', { name: 'Sign out' }).click()
    await expect(tab1).toHaveURL(/\/login/)
    await expect(tab1.getByRole('heading', { name: 'Sign in to HMS' })).toBeVisible()

    // The sign-out reaches tab 2: nothing rendered, nothing cached.
    await tab2.bringToFront()
    await expect(tab2.getByTestId('patient-row')).toHaveCount(0)
    await expect(tab2.locator('body')).not.toContainText(ANY_PHI)
    for (const tab of [tab1, tab2]) {
      await expect.poll(async () => (await queryCacheDump(tab)) ?? 'QueryClientProvider not found').not.toMatch(ANY_PHI)
      expect(await queryCacheDump(tab), 'QueryClientProvider not found in the React tree').not.toBeNull()
    }

    // Web storage: no auth session (supabase storageKey "hms.auth*") and no PHI in either tab.
    for (const tab of [tab1, tab2]) {
      await expect
        .poll(async () => {
          const storage = await webStorage(tab)
          return [...Object.keys(storage.local), ...Object.keys(storage.session)].filter((k) => k.startsWith('hms.auth') && k !== 'hms.auth.events')
        })
        .toEqual([])
      const serialized = JSON.stringify(await webStorage(tab))
      expect(serialized).not.toMatch(ANY_PHI)
      expect(serialized).not.toMatch(/access_token|refresh_token/)
    }

    // History back / direct navigation to a PHI page shows no cached PHI.
    await tab1.goBack()
    await expect(tab1).toHaveURL(/\/login/)
    await expect(tab1.locator('body')).not.toContainText(ANY_PHI)
    await tab2.goto('/patients')
    await expect(tab2).toHaveURL(/\/login/)
    await expect(tab2.getByTestId('patient-row')).toHaveCount(0)
    await expect(tab2.locator('body')).not.toContainText(ANY_PHI)
  })
})
