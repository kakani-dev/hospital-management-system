import { describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { AuthProvider } from './AuthProvider'
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router'

describe('cold starts never end the session', () => {
  it('a 503/timeout-ish failure keeps the user signed in and shows a recoverable error', async () => {
    let calls = 0
    stubFetch({
      'GET /api/v1/me': () => {
        calls++
        return json({ title: 'Service unavailable', status: 503, code: 'service_unavailable' }, 503, { 'Retry-After': '5' })
      },
      'GET /health/live': () => json({ title: 'Service unavailable' }, 503),
    })
    const auth = fakeAuthClient({ session: fakeSession() })
    renderWithProviders(<App />, { path: '/patients', auth })
    // GETs are retried (3 retries after the first attempt), then the screen offers Retry - no sign-out.
    expect(await screen.findByTestId('context-error')).toHaveTextContent(/could not load your hospital context/i)
    expect(calls).toBe(4)
    expect(auth.signOut).not.toHaveBeenCalled()
    expect(screen.queryByRole('heading', { name: /sign in/i })).not.toBeInTheDocument()
  })

  it('a 401 refreshes the session once and replays the request with the new token', async () => {
    const seen: (string | null)[] = []
    stubFetch({
      'GET /api/v1/me': (_url, init) => {
        const authz = new Headers(init.headers).get('Authorization')
        seen.push(authz)
        return authz === 'Bearer token-1' ? json({ title: 'Unauthorized', status: 401 }, 401) : json(meFor())
      },
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    const auth = fakeAuthClient({ session: fakeSession() })
    renderWithProviders(<App />, { path: '/', auth })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))
    expect(auth.refreshSession).toHaveBeenCalledTimes(1)
    expect(seen).toEqual(['Bearer token-1', 'Bearer token-refreshed-1'])
    expect(auth.signOut).not.toHaveBeenCalled()
  })

  it('warms the edge up after a successful sign-in (and not after a failed one)', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meFor()), 'GET /health/live': () => json({ status: 'Healthy' }) })
    const warmup = vi.fn()
    const auth = fakeAuthClient()
    const user = userEvent.setup()
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <AuthProvider client={auth} warmup={warmup}>
          <MemoryRouter initialEntries={['/login']}>
            <App />
          </MemoryRouter>
        </AuthProvider>
      </QueryClientProvider>,
    )
    await user.type(await screen.findByLabelText(/email/i), 'admin@alpha.example')
    await user.type(screen.getByLabelText(/password/i), 'wrong-password')
    await user.click(screen.getByRole('button', { name: /sign in/i }))
    expect(await screen.findByText(/invalid login credentials/i)).toBeInTheDocument()
    expect(warmup).not.toHaveBeenCalled()
    await user.clear(screen.getByLabelText(/password/i))
    await user.type(screen.getByLabelText(/password/i), 'correct-horse')
    await user.click(screen.getByRole('button', { name: /sign in/i }))
    await waitFor(() => expect(warmup).toHaveBeenCalledTimes(1))
  })
})
