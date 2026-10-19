import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

const desktopWidth = window.innerWidth
afterEach(() => {
  vi.unstubAllGlobals()
  Object.defineProperty(window, 'innerWidth', { configurable: true, writable: true, value: desktopWidth })
})

const LONG = 'Synthetic Sri Venkateswara Multi-Speciality Hospital & Research Centre'
const routes = () =>
  stubFetch({
    'GET /api/v1/me': () =>
      json(meFor({ activeBranchId: ALPHA_EAST, memberships: [{ tenantId: meFor().activeTenantId!, tenantName: LONG, branchId: null, branchName: null, role: 'tenant_admin' }] })),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'POST /api/v1/me/context': () => json({}),
  })

describe('responsive header (hospital / branch context)', () => {
  it('desktop: the full switcher sits in the header and none in the sidebar', async () => {
    routes()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    const ctx = await screen.findByTestId('tenant-context')
    expect(ctx).toHaveAttribute('data-variant', 'inline')
    expect(within(document.querySelector<HTMLElement>('header.app-header')!).getByLabelText('Branch')).toHaveValue(ALPHA_EAST)
    expect(screen.queryByTestId('compact-context')).not.toBeInTheDocument()
    expect(screen.queryByTestId('sidebar-context')).not.toBeInTheDocument()
  })

  it('phone: the header keeps a compact summary; the selects move into the navigation drawer', async () => {
    Object.defineProperty(window, 'innerWidth', { configurable: true, writable: true, value: 390 })
    routes()
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })

    const compact = await screen.findByTestId('compact-context')
    await waitFor(() => expect(compact).toHaveTextContent(LONG))
    expect(compact).toHaveTextContent('Alpha East')
    expect(compact).toHaveAccessibleName(`Hospital ${LONG}, branch Alpha East. Change hospital or branch`)
    // Only one switcher is mounted (unique labels/test ids), and it is not in the header.
    expect(screen.getAllByTestId('tenant-context')).toHaveLength(1)
    expect(within(document.querySelector<HTMLElement>('header.app-header')!).queryByLabelText('Branch')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument() // label kept for AT

    expect(compact).toHaveAttribute('aria-expanded', 'false')
    await user.click(compact)
    expect(compact).toHaveAttribute('aria-expanded', 'true')
    const drawer = screen.getByTestId('sidebar-context')
    expect(within(drawer).getByTestId('tenant-context')).toHaveAttribute('data-variant', 'stacked')
    expect(within(drawer).getByLabelText('Branch')).toHaveValue(ALPHA_EAST)
    expect(drawer).toHaveTextContent(LONG)
  })
})
