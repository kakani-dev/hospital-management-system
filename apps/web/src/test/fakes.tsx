import type { ReactNode } from 'react'
import { render } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { vi } from 'vitest'
import type { Session } from '@supabase/supabase-js'
import { AuthProvider, type AuthClient } from '../features/auth/AuthProvider'
import type { CurrentUser } from '../lib/api/types'

export const ALPHA = '11111111-1111-4111-8111-111111111111'
export const BETA = '22222222-2222-4222-8222-222222222222'
export const ALPHA_MAIN = 'a1111111-0000-4000-8000-000000000001'
export const ALPHA_EAST = 'a1111111-0000-4000-8000-000000000002'

export function fakeSession(email = 'admin@alpha.example', token = 'token-1'): Session {
  return {
    access_token: token,
    refresh_token: 'refresh',
    expires_in: 3600,
    token_type: 'bearer',
    user: { id: '0a000000-0000-4000-8000-000000000001', email, app_metadata: {}, user_metadata: {}, aud: 'authenticated', created_at: '' },
  } as Session
}

/** In-memory stand-in for supabase.auth (only the methods AuthProvider uses). */
export function fakeAuthClient(opts: { session?: Session | null; password?: string } = {}) {
  let session: Session | null = opts.session ?? null
  let refreshCount = 0
  const listeners = new Set<(event: string, s: Session | null) => void>()
  const client = {
    getSession: vi.fn(async () => ({ data: { session }, error: null })),
    onAuthStateChange: vi.fn((cb: (event: string, s: Session | null) => void) => {
      listeners.add(cb)
      return { data: { subscription: { unsubscribe: () => listeners.delete(cb) } } }
    }),
    signInWithPassword: vi.fn(async ({ email, password }: { email: string; password: string }) => {
      if (password !== (opts.password ?? 'correct-horse')) {
        return { data: { session: null, user: null }, error: { message: 'Invalid login credentials' } }
      }
      session = fakeSession(email)
      return { data: { session, user: session.user }, error: null }
    }),
    signOut: vi.fn(async () => {
      session = null
      return { error: null }
    }),
    refreshSession: vi.fn(async () => {
      refreshCount += 1
      session = session ? { ...session, access_token: `token-refreshed-${refreshCount}` } : null
      return { data: { session, user: session?.user ?? null }, error: null }
    }),
  }
  return client as unknown as AuthClient & typeof client
}

export function meFor(overrides: Partial<CurrentUser> = {}): CurrentUser {
  return {
    userId: '0a000000-0000-4000-8000-000000000001',
    email: 'admin@alpha.example',
    activeTenantId: ALPHA,
    activeBranchId: null,
    roles: ['tenant_admin'],
    accessibleBranches: [
      { id: ALPHA_MAIN, name: 'Alpha Main' },
      { id: ALPHA_EAST, name: 'Alpha East' },
    ],
    memberships: [{ tenantId: ALPHA, tenantName: 'Demo Alpha Hospital', branchId: null, branchName: null, role: 'tenant_admin' }],
    ...overrides,
  }
}

type Handler = (url: URL, init: RequestInit) => Response | Promise<Response>

export function json(body: unknown, status = 200) {
  return new Response(status === 204 ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

/** Routes fetch calls by "METHOD /path" and records them. */
export function stubFetch(routes: Record<string, Handler>) {
  const calls: { method: string; path: string; headers: Headers; body: unknown }[] = []
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input), 'http://localhost')
    const method = (init.method ?? 'GET').toUpperCase()
    calls.push({ method, path: url.pathname, headers: new Headers(init.headers), body: init.body ? JSON.parse(String(init.body)) : undefined })
    const handler = routes[`${method} ${url.pathname}`]
    return handler ? handler(url, init) : json({ title: 'Not found' }, 404)
  })
  vi.stubGlobal('fetch', fetchMock)
  return calls
}

export function renderWithProviders(ui: ReactNode, { path = '/', auth }: { path?: string; auth: AuthClient | null }) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider client={auth}>
        <MemoryRouter initialEntries={[path]}>{ui}</MemoryRouter>
      </AuthProvider>
    </QueryClientProvider>,
  )
}
