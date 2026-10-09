import { defineConfig, devices } from '@playwright/test'

/**
 * Browser E2E for the web app with the API and Supabase Auth MOCKED in the page (page.route,
 * see mocked/mock-backend.ts). No database, .NET or mock-auth server needed: it pins the web side
 * of the PR #1 contracts (X-Hms-Tenant, POST patient search, invitations, 202 add-member,
 * sessionStorage session, idle logoff) and the Sprint 2 screens (patients, schedules, calendar,
 * check-in, OPD queue). The full-stack suite is playwright.config.ts.
 *
 *   npm run e2e:mocked
 */
const PORT = Number(process.env.E2E_MOCKED_PORT ?? 4174)
// Never contacted: every request to it is answered by page.route (keep in sync with mocked/mock-backend.ts).
const MOCK_AUTH_URL = 'http://127.0.0.1:59999'
// Separate outDir so this build (mock auth URL baked in) never overwrites apps/web/dist.
const OUT_DIR = 'node_modules/.e2e-mocked-dist'

export default defineConfig({
  testDir: './mocked',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['list'], ['junit', { outputFile: 'test-results/junit-mocked.xml' }]] : 'list',
  outputDir: 'test-results/mocked',
  use: { baseURL: `http://localhost:${PORT}`, trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  projects: [{ name: 'chromium-mocked', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `npm --prefix ../../apps/web run build -- --outDir ${OUT_DIR} && npm --prefix ../../apps/web run preview -- --outDir ${OUT_DIR} --port ${PORT}`,
    url: `http://localhost:${PORT}`,
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      VITE_SUPABASE_URL: MOCK_AUTH_URL,
      VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_mocked_e2e_placeholder',
      VITE_API_BASE_URL: '',
      VITE_IDLE_TIMEOUT_MINUTES: '15',
      // Resilience knobs shrunk so cold-start specs run in seconds (defaults: lib/config.ts, .env.example).
      VITE_WAKING_BANNER_AFTER_MS: '1000',
      VITE_WAKING_STILL_AFTER_MS: '60000',
      VITE_API_GET_TIMEOUT_MS: '10000',
      VITE_API_WRITE_TIMEOUT_MS: '3000',
      VITE_API_RETRY_BASE_DELAY_MS: '200',
      VITE_API_RETRY_MAX_DELAY_MS: '1000',
    },
  },
})
