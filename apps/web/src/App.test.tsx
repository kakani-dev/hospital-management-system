import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from './App'
import { ALPHA, ALPHA_EAST, BETA, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from './test/fakes'

afterEach(() => vi.unstubAllGlobals())

const page = { items: [], page: 1, pageSize: 25, totalCount: 0 }

describe('Authentication', () => {
  it('redirects unauthenticated users to login', async () => {
    stubFetch({})
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient() })
    expect(await screen.findByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
  })

  it('warns when Supabase is not configured and disables sign-in', async () => {
    stubFetch({})
    renderWithProviders(<App />, { path: '/login', auth: null })
    expect(await screen.findByText(/authentication is not configured/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /sign in/i })).toBeDisabled()
  })

  it('validates, rejects bad credentials, then signs in and sends the bearer token', async () => {
    const calls = stubFetch({ 'GET /api/v1/me': () => json(meFor()), 'GET /health/live': () => json({ status: 'Healthy' }) })
    const auth = fakeAuthClient()
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/login', auth })

    await user.click(await screen.findByRole('button', { name: /sign in/i }))
    expect(await screen.findByText(/valid email address/i)).toBeInTheDocument()

    await user.type(screen.getByLabelText(/email/i), 'admin@alpha.example')
    await user.type(screen.getByLabelText(/password/i), 'wrong-password')
    await user.click(screen.getByRole('button', { name: /sign in/i }))
    expect(await screen.findByText(/invalid login credentials/i)).toBeInTheDocument()

    await user.clear(screen.getByLabelText(/password/i))
    await user.type(screen.getByLabelText(/password/i), 'correct-horse')
    await user.click(screen.getByRole('button', { name: /sign in/i }))

    expect(await screen.findByRole('heading', { name: /dashboard/i })).toBeInTheDocument()
    expect(await screen.findByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital')
    const meCall = calls.find((c) => c.path === '/api/v1/me')!
    expect(meCall.headers.get('Authorization')).toBe('Bearer token-1')
    expect([...meCall.headers.keys()].some((k) => k.includes('tenant'))).toBe(false)
  })

  it('signs out and returns to login', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meFor()), 'GET /health/live': () => json({ status: 'Healthy' }) })
    const auth = fakeAuthClient({ session: fakeSession() })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth })
    await user.click(await screen.findByRole('button', { name: /sign out/i }))
    expect(await screen.findByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
    expect(auth.signOut).toHaveBeenCalled()
  })
})

describe('Tenant and branch switching', () => {
  it('switches tenant via the server, refreshes the token, and reloads context', async () => {
    let active = ALPHA
    const memberships = [
      { tenantId: ALPHA, tenantName: 'Demo Alpha Hospital', branchId: ALPHA_EAST, branchName: 'Alpha East', role: 'doctor' },
      { tenantId: BETA, tenantName: 'Demo Beta Clinic', branchId: null, branchName: null, role: 'doctor' },
    ]
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeTenantId: active, roles: ['doctor'], memberships })),
      'POST /api/v1/me/context': (_u, init) => {
        active = JSON.parse(String(init.body)).tenantId
        return json(null, 204)
      },
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    const auth = fakeAuthClient({ session: fakeSession('consultant@shared.example') })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth })

    const hospital = await screen.findByLabelText('Hospital')
    await user.selectOptions(hospital, BETA)

    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Beta Clinic'))
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ tenantId: BETA, branchId: null })
    expect(auth.refreshSession).toHaveBeenCalledTimes(1)
    // Requests after the switch carry the refreshed token.
    expect(calls.at(-1)!.headers.get('Authorization')).toBe('Bearer token-refreshed-1')
  })

  it('shows a denial when the server rejects the switch and does not refresh the token', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'POST /api/v1/me/context': () => json({ title: 'Forbidden' }, 403),
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    const auth = fakeAuthClient({ session: fakeSession() })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth })
    await user.selectOptions(await screen.findByLabelText('Branch'), ALPHA_EAST)
    expect(await screen.findByText(/switch denied/i)).toBeInTheDocument()
    expect(auth.refreshSession).not.toHaveBeenCalled()
  })
})

describe('Navigation by role', () => {
  it('shows admin pages only to tenant admins', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json(page),
    })
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByRole('link', { name: /register patient/i })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /members/i })).not.toBeInTheDocument()
  })

  it('blocks the members page for non-admins (UX guard)', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meFor({ roles: ['doctor'] })) })
    renderWithProviders(<App />, { path: '/admin/members', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByText(/only tenant admins/i)).toBeInTheDocument()
  })
})
