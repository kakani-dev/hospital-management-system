import { defineConfig, devices } from '@playwright/test'

/**
 * Full-stack E2E: web (vite preview) + HMS API (dotnet) + mock Supabase Auth (tests/mock-auth),
 * all against a THROWAWAY local Postgres database (default hms_e2e) prepared with
 *   npm run e2e:db   (migrations + synthetic seed + local hms_api_login role)
 * The API connects as the low-privilege hms_api_login role, so RLS applies to every request.
 * Never point any of these at a real Supabase project or production.
 */
const WEB_PORT = Number(process.env.E2E_PORT ?? 4173)
const API_PORT = Number(process.env.E2E_API_PORT ?? 8080)
const AUTH_PORT = Number(process.env.E2E_AUTH_PORT ?? 54321)
const DB_NAME = process.env.E2E_DB ?? 'hms_e2e'
const PG_HOST = process.env.E2E_PG_HOST ?? 'localhost'
const PG_ADMIN_PASSWORD = process.env.E2E_PG_PASSWORD ?? 'postgres'
const BASE_URL = `http://localhost:${WEB_PORT}`
const AUTH_URL = `http://localhost:${AUTH_PORT}`

export const e2eEnv = {
  baseUrl: BASE_URL,
  authUrl: AUTH_URL,
  adminDbUrl: `postgresql://postgres:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/${DB_NAME}`,
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
      // E2E_API_COMMAND lets CI run a prebuilt (e.g. self-contained) gateway instead of `dotnet run`.
      command: process.env.E2E_API_COMMAND ?? 'dotnet run --project ../../backend/gateway/Hms.Gateway --no-launch-profile',
      url: `http://localhost:${API_PORT}/health/ready`,
      reuseExistingServer: reuse,
      timeout: 240_000,
      env: {
        ASPNETCORE_ENVIRONMENT: 'E2E',
        ASPNETCORE_URLS: `http://localhost:${API_PORT}`,
        ConnectionStrings__HmsDatabase: `Host=${PG_HOST};Port=5432;Database=${DB_NAME};Username=hms_api_login;Password=hms_api_local_only`,
        Auth__Supabase__ProjectUrl: AUTH_URL,
        Auth__Supabase__AllowInsecureHttp: 'true',
        RateLimiting__PermitPerMinute: '10000',
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
