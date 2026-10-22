/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'

// https://vite.dev/config/
const apiTarget = process.env.VITE_DEV_API_PROXY ?? 'http://localhost:8080'
// Local dev / E2E only: forward API calls to the ASP.NET Core gateway (same-origin, no CORS needed).
const apiProxy = {
  '/api': { target: apiTarget, changeOrigin: true },
  '/health': { target: apiTarget, changeOrigin: true },
}

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Ported Tailux starter modules live in src/tailux and import each other as @tailux/...
  resolve: { alias: { '@tailux': fileURLToPath(new URL('./src/tailux', import.meta.url)) } },
  build: {
    rolldownOptions: {
      output: {
        // Long-lived vendor chunks (cache across app deploys) and an entry chunk under 500 kB.
        // supabase-js (~200 kB) is only bundled when VITE_SUPABASE_* are set, as in real builds.
        codeSplitting: {
          groups: [
            { name: 'vendor-supabase', test: /node_modules[\\/]@supabase[\\/]/ },
            { name: 'vendor-react', test: /node_modules[\\/](react|react-dom|scheduler|react-router)[\\/]/ },
            // Tailux UI shell dependencies (Headless UI + Floating UI, TanStack Table, Sonner).
            {
              name: 'vendor-ui',
              test: /node_modules[\\/](@headlessui|@floating-ui|@react-aria|@tanstack[\\/](react-table|table-core|react-virtual|virtual-core)|sonner|clsx)[\\/]/,
            },
          ],
        },
      },
    },
  },
  server: { port: 5173, strictPort: true, proxy: apiProxy },
  preview: { port: 4173, strictPort: true, proxy: apiProxy },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    // userEvent.type through the zone combobox takes ~5s on a loaded CI runner; the 5s default
    // timed out there and the still-running test then broke the next one in the file.
    testTimeout: 20000,
    // Component tests use the real retry policy with tiny waits (Retry-After is capped by the max);
    // the policy itself is unit-tested with fake timers and explicit values (client.resilience.test.ts).
    env: {
      VITE_API_RETRY_BASE_DELAY_MS: '10',
      VITE_API_RETRY_MAX_DELAY_MS: '40',
    },
  },
})
