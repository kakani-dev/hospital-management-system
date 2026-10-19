import { describe, expect, it } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import { App } from '../../App'
import { fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

const NO_ACCESS = /do not have access to any branch/i

describe('no false "no branch access" warning', () => {
  it.each(['/reception/check-in', '/queue', '/appointments', '/schedules'])('%s: while /me is loading, shows a placeholder, not the warning', async (path) => {
    stubFetch({ 'GET /api/v1/me': () => new Promise<Response>(() => {}) })
    renderWithProviders(<App />, { path, auth: fakeAuthClient({ session: fakeSession() }) })
    expect((await screen.findAllByRole('status')).length).toBeGreaterThan(0)
    await new Promise((r) => setTimeout(r, 50))
    expect(screen.queryByText(NO_ACCESS)).not.toBeInTheDocument()
    expect(screen.queryByTestId('forbidden')).not.toBeInTheDocument()
  })

  it('when /me fails, explains it once with Retry instead of "no access" or "forbidden"', async () => {
    let fail = true
    stubFetch({
      'GET /api/v1/me': () => (fail ? json({ title: 'Internal error' }, 500) : json(meWithRoles(['receptionist']))),
      'GET /api/v1/branches': () => json([]),
      'GET /api/v1/practitioners': () => json([]),
      'GET /api/v1/appointments': () => json({ items: [], page: 1, pageSize: 100, totalCount: 0 }),
    })
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('context-error')).toHaveTextContent(/your session is still active/i)
    expect(screen.queryByText(NO_ACCESS)).not.toBeInTheDocument()
    expect(screen.queryByTestId('forbidden')).not.toBeInTheDocument()
    fail = false
    screen.getByRole('button', { name: 'Retry' }).click()
    expect(await screen.findByRole('heading', { name: 'Reception check-in' })).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('context-error')).not.toBeInTheDocument())
  })

  it('still warns when /me really has no accessible branch', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'], accessibleBranches: [] })),
      'GET /api/v1/branches': () => json([]),
      'GET /api/v1/practitioners': () => json([]),
    })
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByText(NO_ACCESS)).toBeInTheDocument()
  })
})
