import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
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

// The page also has the "Create invite link" form with the same labels: scope to "Add member".
const addForm = async () => within(await screen.findByRole('form', { name: 'Add member' }))

async function addMember(email: string) {
  const user = userEvent.setup()
  renderWithProviders(<App />, { path: '/admin/members', auth: fakeAuthClient({ session: fakeSession() }) })
  const form = await addForm()
  await user.type(form.getByLabelText('Email'), email)
  await user.selectOptions(form.getByLabelText('Role'), 'nurse')
  await user.click(form.getByRole('button', { name: 'Add member' }))
}

describe('Members page: add member (B1, no account enumeration)', () => {
  it('shows the message from the 202 response body and posts no tenant id', async () => {
    const calls = stubFetch(routes(() => json({ message: 'If an account exists for that email, an invitation has been sent.' }, 202)))
    await addMember('maybe@synthetic.example')
    expect(await screen.findByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeInTheDocument()
    const post = calls.find((c) => c.method === 'POST')!
    expect(post.body).toEqual({ email: 'maybe@synthetic.example', role: 'nurse', branchId: null })
    expect((await addForm()).getByLabelText('Email')).toHaveValue('')
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

  it('offers only "All branches" for tenant admins and shows the API 400 on the branch field', async () => {
    const branch = { id: 'a1111111-0000-4000-8000-000000000002', code: 'east', name: 'Alpha East', timezone: 'Asia/Kolkata', isActive: true }
    const calls = stubFetch({
      ...routes(() => json({ title: 'Validation', status: 400, errors: { branchId: ['tenant_admin is tenant-wide: omit branchId.'] } }, 400)),
      'GET /api/v1/branches': () => json([branch]),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/admin/members', auth: fakeAuthClient({ session: fakeSession() }) })
    const form = await addForm()
    const scope = form.getByLabelText('Branch scope')
    await within(scope).findByRole('option', { name: 'Alpha East' })
    await user.selectOptions(scope, 'Alpha East')
    expect(scope).toHaveValue(branch.id)

    await user.selectOptions(form.getByLabelText('Role'), 'tenant_admin')
    expect(scope).toHaveValue('')
    expect(within(scope).queryByRole('option', { name: 'Alpha East' })).not.toBeInTheDocument()

    // Server-side 400 (e.g. an older form) is still shown on the field.
    await user.type(form.getByLabelText('Email'), 'boss@synthetic.example')
    await user.click(form.getByRole('button', { name: 'Add member' }))
    expect(await screen.findByText('tenant_admin is tenant-wide: omit branchId.')).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ email: 'boss@synthetic.example', role: 'tenant_admin', branchId: null })
  })

  it('does not insert anything into the members list after a 202 (pending invites are hidden)', async () => {
    const calls = stubFetch(routes(() => json({ message: ADD_MEMBER_GENERIC_MESSAGE }, 202)))
    await addMember('pending@synthetic.example')
    expect(await screen.findByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeInTheDocument()
    await waitFor(() => expect(calls.filter((c) => c.method === 'GET' && c.path === '/api/v1/members')).toHaveLength(2))
    expect(screen.queryByTestId('member-row')).not.toBeInTheDocument()
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
