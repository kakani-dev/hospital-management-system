import { defineConfig, devices } from '@playwright/test'

/**
 * Full-stack E2E: web (vite preview) + HMS API (dotnet) + mock Supabase Auth (tests/mock-auth),
 * all against a THROWAWAY local Postgres database (default hms_e2e) prepared with
 *   npm run e2e:db   (migrations + synthetic seed + local hms_api_login role)
 * The API is the microservices stack (scripts/dev/run-microservices.sh): identity, patients and
 * scheduling, each logging in as its own low-privilege role (RLS applies to every request), behind
 * the YARP edge on API_PORT. Playwright waits on the edge's /health/ready, which only turns green
 * once every service is ready. E2E_API_COMMAND overrides the dev script.
 * Never point any of these at a real Supabase project or production.
 */
const WEB_PORT = Number(process.env.E2E_PORT ?? 4173)
const API_PORT = Number(process.env.E2E_API_PORT ?? 8080)
const AUTH_PORT = Number(process.env.E2E_AUTH_PORT ?? 54321)
const DB_NAME = process.env.E2E_DB ?? 'hms_e2e'
const PG_HOST = process.env.E2E_PG_HOST ?? 'localhost'
const PG_PORT = process.env.E2E_PG_PORT ?? '5432'
const PG_ADMIN_PASSWORD = process.env.E2E_PG_PASSWORD ?? 'postgres'
const BASE_URL = `http://localhost:${WEB_PORT}`
const AUTH_URL = `http://localhost:${AUTH_PORT}`

export const e2eEnv = {
  baseUrl: BASE_URL,
  authUrl: AUTH_URL,
  adminDbUrl: `postgresql://postgres:${PG_ADMIN_PASSWORD}@${PG_HOST}:${PG_PORT}/${DB_NAME}`,
  password: process.env.E2E_PASSWORD ?? 'synthetic-demo-pass',
}
process.env.E2E_ADMIN_DB_URL ??= e2eEnv.adminDbUrl
process.env.E2E_AUTH_URL ??= AUTH_URL
process.env.E2E_PASSWORD ??= e2eEnv.password

const reuse = !process.env.CI

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1, // specs share one database; keep ordering deterministic
  reporter: process.env.CI
    ? [['list'], ['junit', { outputFile: 'test-results/junit.xml' }], ['html', { open: 'never', outputFolder: 'playwright-report' }]]
    : 'list',
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
  webServer: [
    {
      name: 'mock-auth',
      command: 'node ../mock-auth/server.mjs',
      url: `${AUTH_URL}/health`,
      reuseExistingServer: reuse,
      timeout: 30_000,
      env: {
        MOCK_AUTH_PORT: String(AUTH_PORT),
        MOCK_AUTH_DB_URL: e2eEnv.adminDbUrl,
        MOCK_AUTH_PASSWORD: e2eEnv.password,
      },
    },
    {
      name: 'api',
      // Default: the microservices stack behind the edge. E2E_API_COMMAND overrides it.
      command: process.env.E2E_API_COMMAND ?? 'bash ../../scripts/dev/run-microservices.sh',
      url: `http://localhost:${API_PORT}/health/ready`,
      reuseExistingServer: reuse,
      timeout: 240_000,
      env: {
        ASPNETCORE_ENVIRONMENT: 'E2E',
        ASPNETCORE_URLS: `http://localhost:${API_PORT}`,
        API_PORT: String(API_PORT),
        // Microservices: base connection; each service appends its own hms_<svc>_login.
        HMS_MS_DB: `Host=${PG_HOST};Port=${PG_PORT};Database=${DB_NAME}`,
        Auth__Supabase__ProjectUrl: AUTH_URL,
        Auth__Supabase__AllowInsecureHttp: 'true',
        RateLimiting__PermitPerMinute: '10000',
        RateLimiting__WarmupPerMinute: '1000',
        Serilog__MinimumLevel__Default: 'Warning',
      },
    },
    {
      name: 'web',
      command: `npm --prefix ../../apps/web run build && npm --prefix ../../apps/web run preview -- --port ${WEB_PORT}`,
      url: BASE_URL,
      reuseExistingServer: reuse,
      timeout: 120_000,
      env: {
        VITE_SUPABASE_URL: AUTH_URL,
        VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_local_e2e_placeholder',
        VITE_DEV_API_PROXY: `http://localhost:${API_PORT}`,
        VITE_API_BASE_URL: '',
      },
    },
  ],
})
