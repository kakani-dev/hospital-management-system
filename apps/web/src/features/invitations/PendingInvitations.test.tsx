import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA, BETA, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const MEMBERSHIP_ID = 'cc000000-0000-4000-8000-000000000001'
const invitation = {
  membershipId: MEMBERSHIP_ID,
  tenantId: BETA,
  tenantName: 'Demo Beta Clinic',
  branchId: null,
  role: 'doctor',
  invitedAt: '2026-10-06T10:00:00Z',
}
const alphaMembership = { tenantId: ALPHA, tenantName: 'Demo Alpha Hospital', branchId: null, branchName: null, role: 'doctor' }
const betaMembership = { tenantId: BETA, tenantName: 'Demo Beta Clinic', branchId: null, branchName: null, role: 'doctor' }

describe('Pending invitations', () => {
  it('lists invitations on the dashboard; Accept calls the API and refetches memberships and invitations', async () => {
    let accepted = false
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['doctor'], memberships: accepted ? [alphaMembership, betaMembership] : [alphaMembership] })),
      'GET /api/v1/me/invitations': () => json(accepted ? [] : [invitation]),
      [`POST /api/v1/me/invitations/${MEMBERSHIP_ID}/accept`]: () => {
        accepted = true
        return json(null, 204)
      },
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession('doctor@alpha.example') }) })

    const row = await screen.findByTestId('invitation-row')
    expect(row).toHaveTextContent('Demo Beta Clinic')
    expect(row).toHaveTextContent(/doctor/i)
    expect(row).toHaveTextContent('All branches')
    // Not a member yet: no hospital switcher until the invitation is accepted.
    expect(screen.queryByRole('combobox', { name: 'Hospital' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Accept invitation to Demo Beta Clinic as doctor' }))

    expect(await screen.findByText(/you joined demo beta clinic as doctor/i)).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('invitation-row')).not.toBeInTheDocument())
    expect(await screen.findByRole('combobox', { name: 'Hospital' })).toBeInTheDocument() // /me refetched: Beta now listed
    const accept = calls.find((c) => c.path.endsWith('/accept'))!
    expect(accept.method).toBe('POST')
    expect(calls.filter((c) => c.path === '/api/v1/me/invitations')).toHaveLength(2)
    expect(calls.filter((c) => c.path === '/api/v1/me').length).toBeGreaterThanOrEqual(2)
  })

  it('reports an invitation that is no longer available (404) and refetches the list', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['doctor'] })),
      'GET /api/v1/me/invitations': () => json([invitation]),
      [`POST /api/v1/me/invitations/${MEMBERSHIP_ID}/accept`]: () => json({ title: 'Not found' }, 404),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: /accept invitation/i }))
    expect(await screen.findByText(/no longer available/i)).toBeInTheDocument()
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/me/invitations')).toHaveLength(2))
  })

  it('renders nothing when there are no invitations', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/me/invitations': () => json([]),
    })
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getByTestId('dashboard-tenant')).toHaveTextContent('Demo Alpha Hospital'))
    expect(screen.queryByRole('region', { name: 'Pending invitations' })).not.toBeInTheDocument()
  })
})
