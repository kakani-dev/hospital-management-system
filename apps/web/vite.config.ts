/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // Local dev: forward API calls to the ASP.NET Core gateway.
      '/api': { target: process.env.VITE_DEV_API_PROXY ?? 'http://localhost:8080', changeOrigin: true },
      '/health': { target: process.env.VITE_DEV_API_PROXY ?? 'http://localhost:8080', changeOrigin: true },
    },
  },
  preview: { port: 4173, strictPort: true },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
  },
})
