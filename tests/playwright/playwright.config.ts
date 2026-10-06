import { defineConfig, devices } from '@playwright/test'

const PORT = Number(process.env.E2E_PORT ?? 4173)
const BASE_URL = process.env.E2E_BASE_URL ?? `http://localhost:${PORT}`

/**
 * Starter E2E suite for the web shell. By default it builds apps/web and serves it with
 * `vite preview`. The API is NOT required: tests assert graceful degradation when it is down.
 * Set E2E_BASE_URL to run against an already-running environment (never production).
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]] : 'list',
  outputDir: 'test-results',
  use: {
    baseURL: BASE_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium-desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'chromium-mobile', use: { ...devices['Pixel 7'] }, grep: /@responsive/ },
  ],
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: `npm --prefix ../../apps/web run build && npm --prefix ../../apps/web run preview -- --port ${PORT}`,
        url: BASE_URL,
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
      },
})
