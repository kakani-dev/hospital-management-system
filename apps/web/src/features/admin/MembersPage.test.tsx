import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ADD_MEMBER_GENERIC_MESSAGE } from '../../lib/api/types'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const routes = (addMember: () => Response) => ({
  'GET /api/v1/me': () => json(meFor()),
  'GET /api/v1/members': () => json([]),
  'GET /api/v1/branches': () => json([]),
  'POST /api/v1/members': addMember,
})

async function addMember(email: string) {
  const user = userEvent.setup()
  renderWithProviders(<App />, { path: '/admin/members', auth: fakeAuthClient({ session: fakeSession() }) })
  await user.type(await screen.findByLabelText('Email'), email)
  await user.selectOptions(screen.getByLabelText('Role'), 'nurse')
  await user.click(screen.getByRole('button', { name: 'Add member' }))
}

describe('Members page: add member (B1, no account enumeration)', () => {
  it('shows the message from the 202 response body and posts no tenant id', async () => {
    const calls = stubFetch(routes(() => json({ message: 'If an account exists for that email, an invitation has been sent.' }, 202)))
    await addMember('maybe@synthetic.example')
    expect(await screen.findByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeInTheDocument()
    const post = calls.find((c) => c.method === 'POST')!
    expect(post.body).toEqual({ email: 'maybe@synthetic.example', role: 'nurse', branchId: null })
    expect(screen.getByLabelText('Email')).toHaveValue('')
  })

  it('falls back to the generic text when the 202 has no body', async () => {
    stubFetch(routes(() => new Response(null, { status: 202 })))
    await addMember('someone@synthetic.example')
    expect(await screen.findByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeInTheDocument()
    expect(screen.queryByText(/no user|not found|already/i)).not.toBeInTheDocument()
  })

  it('still maps 400 validation errors to fields', async () => {
    stubFetch(routes(() => json({ title: 'Validation', status: 400, errors: { email: ['Email is too long'] } }, 400)))
    await addMember('x@synthetic.example')
    expect(await screen.findByText('Email is too long')).toBeInTheDocument()
    expect(screen.getByText(/fix the highlighted fields/i)).toBeInTheDocument()
  })

  it('shows invited members without suspend/reactivate actions', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/branches': () => json([]),
      'GET /api/v1/members': () =>
        json([{ id: 'm1', userId: 'u1', email: 'new@synthetic.example', displayName: null, role: 'nurse', branchId: null, branchName: null, status: 'invited' }]),
    })
    renderWithProviders(<App />, { path: '/admin/members', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getByTestId('member-row')).toHaveTextContent('invited'))
    expect(screen.queryByRole('button', { name: /suspend|reactivate/i })).not.toBeInTheDocument()
  })
})
