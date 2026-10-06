import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient } from '@tanstack/react-query'
import { App } from '../../App'
import { AUTH_CHANNEL_NAME } from '../../lib/auth/authChannel'
import { ALPHA, BETA, fakeAuthClient, fakeJwt, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const memberships = [
  { tenantId: ALPHA, tenantName: 'Demo Alpha Hospital', branchId: null, branchName: null, role: 'doctor' },
  { tenantId: BETA, tenantName: 'Demo Beta Clinic', branchId: null, branchName: null, role: 'doctor' },
]
const page = { items: [], page: 1, pageSize: 25, totalCount: 0 }
const EMAIL = 'consultant@shared.example'

/** Server whose resolved tenant (`server.tenant`) can change underneath the SPA, like M3 describes. */
function setup(opts: { headers?: boolean; refreshedTenant?: () => string | null } = {}) {
  const server = { tenant: ALPHA }
  const header = () => (opts.headers ? { 'X-Hms-Tenant': server.tenant } : undefined)
  const calls = stubFetch({
    'GET /api/v1/me': () => json(meFor({ email: EMAIL, activeTenantId: server.tenant, roles: ['doctor'], memberships }), 200, header()),
    'GET /api/v1/patients': () => json(page, 200, header()),
    'POST /api/v1/patients/search': () => json(page, 200, header()),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'POST /api/v1/me/context': (_u, init) => {
      server.tenant = JSON.parse(String(init.body)).tenantId
      return json(null, 204)
    },
  })
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const clear = vi.spyOn(queryClient, 'clear')
  const auth = fakeAuthClient({ session: fakeSession(EMAIL, fakeJwt({ tenant_id: ALPHA })), refreshedTenant: opts.refreshedTenant })
  return { server, calls, queryClient, clear, auth }
}

describe('M3: tenant drift guard', () => {
  it('clears the cache and shows a banner when a refreshed token carries another tenant', async () => {
    const { server, queryClient, clear, auth } = setup()
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))
    expect(clear).not.toHaveBeenCalled()

    // Another tab/device switched the user to Beta; supabase-js refreshes (or broadcasts) a new token.
    server.tenant = BETA
    act(() => auth.emit('TOKEN_REFRESHED', fakeSession(EMAIL, fakeJwt({ tenant_id: BETA }))))

    const banner = await screen.findByTestId('tenant-changed-banner')
    expect(clear).toHaveBeenCalled()
    expect(banner).toHaveTextContent(/was Demo Alpha Hospital/)
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Beta Clinic'))
    expect(banner).toHaveTextContent(/now belongs to Demo Beta Clinic/)

    await userEvent.setup().click(screen.getByRole('button', { name: /dismiss/i }))
    expect(screen.queryByTestId('tenant-changed-banner')).not.toBeInTheDocument()
  })

  it('does nothing when the refreshed token keeps the displayed tenant (or has no tenant claim)', async () => {
    const { clear, auth } = setup()
    renderWithProviders(<App />, { path: '/', auth })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))
    act(() => auth.emit('TOKEN_REFRESHED', fakeSession(EMAIL, fakeJwt({ tenant_id: ALPHA }))))
    act(() => auth.emit('TOKEN_REFRESHED', fakeSession(EMAIL, 'opaque-token-without-claims')))
    await new Promise((r) => setTimeout(r, 20))
    expect(screen.queryByTestId('tenant-changed-banner')).not.toBeInTheDocument()
    expect(clear).not.toHaveBeenCalled()
  })

  it('clears the cache and shows a banner when an API response resolves another tenant (X-Hms-Tenant)', async () => {
    const { server, queryClient, clear, auth } = setup({ headers: true })
    renderWithProviders(<App />, { path: '/patients', auth, queryClient })
    expect(await screen.findByTestId('patients-empty')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('tenant-name')).toHaveTextContent('Demo Alpha Hospital'))
    expect(clear).not.toHaveBeenCalled()

    // Without the hook the API falls back to the stored context: the next call silently resolves Beta.
    server.tenant = BETA
    await userEvent.setup().type(screen.getByLabelText('Search patients'), 'x')
    expect(await screen.findByTestId('tenant-changed-banner')).toBeInTheDocument()
    expect(clear).toHaveBeenCalled()
    await waitFor(() => expect(screen.getByTestId('tenant-name')).toHaveTextContent('Demo Beta Clinic'))
  })

  it('an intentional tenant switch clears the cache without raising the banner', async () => {
    let refreshed = ALPHA
    const { server, calls, queryClient, clear, auth } = setup({ headers: true, refreshedTenant: () => refreshed })
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    const hospital = await screen.findByLabelText('Hospital')
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))

    refreshed = BETA
    await userEvent.setup().selectOptions(hospital, BETA)
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Beta Clinic'))
    expect(server.tenant).toBe(BETA)
    expect(clear).toHaveBeenCalledTimes(1)
    expect(auth.refreshSession).toHaveBeenCalledTimes(1)
    expect(screen.queryByTestId('tenant-changed-banner')).not.toBeInTheDocument()
    // /me was refetched after the switch with the refreshed (Beta) token.
    const lastMe = calls.filter((c) => c.path === '/api/v1/me').at(-1)!
    expect(lastMe.headers.get('Authorization')).toBe(`Bearer ${fakeJwt({ tenant_id: BETA })}`)
  })

  it('also clears the cache on a branch-only switch', async () => {
    const { queryClient, clear, auth } = setup()
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    await screen.findByTestId('tenant-context')
    await userEvent.setup().selectOptions(screen.getByLabelText('Branch'), screen.getAllByRole('option', { name: 'Alpha East' })[0]!)
    await waitFor(() => expect(clear).toHaveBeenCalledTimes(1))
  })
})

describe('M3: sign-out always clears the query cache', () => {
  it('SIGNED_OUT from another tab or a failed refresh clears the cache and returns to login', async () => {
    const { queryClient, clear, auth } = setup()
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))
    expect(queryClient.getQueryData(['me'])).toBeDefined()

    act(() => auth.emit('SIGNED_OUT', null))

    expect(await screen.findByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
    expect(screen.getByText(/your session ended/i)).toBeInTheDocument()
    expect(clear).toHaveBeenCalled()
    expect(queryClient.getQueryData(['me'])).toBeUndefined()
  })

  it('an explicit sign-out in another HMS tab signs this tab out locally (sessionStorage copy)', async () => {
    const { queryClient, clear, auth } = setup()
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))

    const otherTab = new BroadcastChannel(AUTH_CHANNEL_NAME)
    otherTab.postMessage({ type: 'signed-out' })
    otherTab.close()

    expect(await screen.findByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
    expect(auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
    expect(clear).toHaveBeenCalled()
    expect(queryClient.getQueryData(['me'])).toBeUndefined()
  })

  it('an explicit sign-out clears the cache and tells the other tabs', async () => {
    const { queryClient, clear, auth } = setup()
    const received: unknown[] = []
    const otherTab = new BroadcastChannel(AUTH_CHANNEL_NAME)
    otherTab.onmessage = (event) => received.push(event.data)
    renderWithProviders(<App />, { path: '/', auth, queryClient })
    await userEvent.setup().click(await screen.findByRole('button', { name: /sign out/i }))

    expect(await screen.findByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
    expect(clear).toHaveBeenCalled()
    expect(queryClient.getQueryData(['me'])).toBeUndefined()
    expect(screen.queryByText(/your session ended/i)).not.toBeInTheDocument()
    await waitFor(() => expect(received).toContainEqual({ type: 'signed-out' }))
    otherTab.close()
  })
})
