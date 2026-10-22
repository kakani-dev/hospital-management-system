import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const TOKEN = 'ab'.repeat(32)
const preview = { tenantName: 'Synthetic Lotus Clinic', role: 'tenant_admin', branchName: null, emailHint: 'a***@lotus.example', expiresOn: '2026-11-01T00:00:00Z' }

describe('Invite link page', () => {
  it('previews the invitation without signing in and sends the user to sign in first', async () => {
    const calls = stubFetch({ [`GET /api/v1/public/invites/${TOKEN}`]: () => json(preview) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/invite/${TOKEN}`, auth: fakeAuthClient() })
    expect(await screen.findByTestId('invite-preview')).toHaveTextContent('a***@lotus.example')
    expect(screen.getByTestId('invite-preview')).toHaveTextContent('All branches')
    await user.click(screen.getByRole('button', { name: 'I already have a password' }))
    expect(await screen.findByRole('button', { name: 'Sign in' })).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
  })

  it('emails a sign-in code, accepts it, then asks the invitee to choose a password', async () => {
    const calls = stubFetch({
      [`GET /api/v1/public/invites/${TOKEN}`]: () => json(preview),
      [`POST /api/v1/public/invites/${TOKEN}/sign-in-code`]: () => json({ expiresOn: '2026-11-01T00:10:00Z' }, 202),
      [`POST /api/v1/public/invites/${TOKEN}/sign-in`]: () => json({ tokenHash: 'hash-1', verificationType: 'magiclink' }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/invite/${TOKEN}`, auth: fakeAuthClient() })
    await user.click(await screen.findByRole('button', { name: 'Email me a sign-in code' }))
    expect(await screen.findByRole('form', { name: 'Sign-in code' })).toBeInTheDocument()
    await user.type(screen.getByRole('textbox', { name: 'Sign-in code' }), '123456')
    await user.click(screen.getByRole('button', { name: 'Sign in with code' }))
    expect(await screen.findByRole('form', { name: 'Choose a password' })).toBeInTheDocument()
    expect(calls.find((c) => c.path.endsWith('/sign-in'))?.body).toEqual({ code: '123456' })
    await user.type(screen.getByLabelText('Password'), 'chosen-by-invitee')
    await user.click(screen.getByRole('button', { name: 'Save password' }))
    expect(await screen.findByRole('button', { name: 'Join Synthetic Lotus Clinic' })).toBeInTheDocument()
  })

  it('claims as the signed-in user and switches into the new hospital', async () => {
    let joined = false
    const calls = stubFetch({
      [`GET /api/v1/public/invites/${TOKEN}`]: () => json(preview),
      'POST /api/v1/me/invite-links/claim': () => {
        joined = true
        return json({ tenantId: ALPHA, tenantName: 'Synthetic Lotus Clinic', role: 'tenant_admin', branchId: null })
      },
      'POST /api/v1/me/context': () => json(meFor()),
      'GET /api/v1/me': () => json(joined ? meFor() : meFor({ memberships: [], roles: [], activeTenantId: null })),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/invite/${TOKEN}`, auth: fakeAuthClient({ session: fakeSession('asha@lotus.example') }) })
    await user.click(await screen.findByRole('button', { name: 'Join Synthetic Lotus Clinic' }))
    await waitFor(() => expect(calls.find((c) => c.path === '/api/v1/me/invite-links/claim')?.body).toEqual({ token: TOKEN }))
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument()
  })

  it('explains an email mismatch (403) without joining', async () => {
    stubFetch({
      [`GET /api/v1/public/invites/${TOKEN}`]: () => json(preview),
      'POST /api/v1/me/invite-links/claim': () => json({ title: 'Forbidden', status: 403, code: 'invite_email_mismatch' }, 403),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/invite/${TOKEN}`, auth: fakeAuthClient({ session: fakeSession('someone-else@alpha.example') }) })
    await user.click(await screen.findByRole('button', { name: 'Join Synthetic Lotus Clinic' }))
    expect(await screen.findByText(/different email address than someone-else@alpha.example/)).toBeInTheDocument()
  })

  it('says when a link is used up or expired (404)', async () => {
    stubFetch({})
    renderWithProviders(<App />, { path: `/invite/${TOKEN}`, auth: fakeAuthClient() })
    expect(await screen.findByText(/not valid any more/)).toBeInTheDocument()
  })
})
