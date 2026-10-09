import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { App } from './App'
import { AuthProvider } from './features/auth/AuthProvider'
import { supabase } from './lib/supabase'
import { apiClient } from './lib/api/client'
import './index.css'

// Retries live in the API client (GET only, transient errors only, Retry-After aware), so React
// Query must not add its own on top: `retry: false` here and in every hook.
const queryClient = new QueryClient({
  defaultOptions: { queries: { refetchOnWindowFocus: false, retry: false }, mutations: { retry: false } },
})

// Wake the edge and the services while the login page / session restore is still on screen
// (CTO contract: unauthenticated GET /api/v1/warmup, once per app load, result ignored).
void apiClient.warmup()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider client={supabase?.auth ?? null}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  </StrictMode>,
)
