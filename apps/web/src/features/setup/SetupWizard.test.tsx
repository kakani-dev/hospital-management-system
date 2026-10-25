import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { setupLaterKey } from './setupState'

afterEach(() => {
  vi.unstubAllGlobals()
  sessionStorage.clear()
})

const openTenant = {
  id: ALPHA,
  code: 'alpha',
  name: 'Demo Alpha Hospital',
  activeBranchId: null,
  roles: ['tenant_admin'],
  timeZone: 'Asia/Kolkata',
  defaultCountryCode: '+91',
  setupStep: 'profile',
  setupCompletedOn: null,
}

function routes(tenant: Record<string, unknown> | undefined, me = meFor()) {
  return stubFetch({
    'GET /api/v1/me': () => json(me),
    'GET /api/v1/tenants/current': () => (tenant ? json(tenant) : json({ title: 'Not found' }, 404)),
    'GET /api/v1/setup': () => json({ step: 'profile', completedOn: null, branchId: ALPHA_MAIN, documentPrefix: 'DEMO' }),
    'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'main', name: 'Main', timezone: 'Asia/Kolkata', timezoneOverride: null, isActive: true }]),
    'GET /health/live': () => json({ status: 'Healthy' }),
  })
}

describe('setup wizard gate', () => {
  it('sends a new hospital admin to the wizard, and Finish later returns to the dashboard', async () => {
    routes(openTenant)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByRole('heading', { name: 'Set up your hospital' })).toBeInTheDocument()
    expect(screen.getByRole('list', { name: 'Setup progress' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Finish later' }))
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument()
    expect(screen.getByTestId('finish-setup')).toHaveTextContent('Finish setup')
    expect(sessionStorage.getItem(setupLaterKey(ALPHA))).toBe('1')
  })

  it('stays on the dashboard when the tenant payload has no setup fields', async () => {
    routes({ id: ALPHA, code: 'alpha', name: 'Demo Alpha Hospital', activeBranchId: null, roles: ['tenant_admin'], timeZone: 'Asia/Kolkata' })
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument()
    expect(screen.queryByTestId('finish-setup')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Set up your hospital' })).not.toBeInTheDocument()
  })

  it('does not redirect a receptionist, and /setup explains the missing permission', async () => {
    routes(openTenant, meWithRoles(['receptionist'], ALPHA_MAIN))
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument()
    expect(screen.queryByTestId('finish-setup')).not.toBeInTheDocument()

    renderWithProviders(<App />, { path: '/setup', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('forbidden')).toBeInTheDocument()
  })

  it('offers Finish setup again from the banner', async () => {
    sessionStorage.setItem(setupLaterKey(ALPHA), '1')
    routes(openTenant)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    const banner = await screen.findByTestId('finish-setup')
    await user.click(within(banner).getByRole('link', { name: 'Finish setup' }))
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Set up your hospital' })).toBeInTheDocument())
  })
})
