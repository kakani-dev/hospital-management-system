import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const OPERATOR = meFor({ email: 'operator@medicore.example', isPlatformAdmin: true, memberships: [], roles: [], activeTenantId: null, accessibleBranches: [] })
const LOTUS = {
  id: '7e000000-0000-4000-8000-000000000001',
  code: 'lotus',
  name: 'Synthetic Lotus Clinic',
  status: 'active',
  timeZone: 'Asia/Kolkata',
  createdOn: '2026-10-19T03:30:00Z',
  branchCount: 2,
  userCount: 5,
  pendingInvites: 1,
  statusReason: null,
}
const REQUEST = {
  id: '5a000000-0000-4000-8000-000000000001',
  hospitalName: 'Synthetic Orchid Hospital',
  timeZone: 'Asia/Dubai',
  contactName: 'Omar Synthetic',
  contactEmail: 'omar@orchid.example',
  phone: '+971 4 555 0100',
  city: 'Dubai',
  status: 'pending',
  decisionReason: null,
  decidedOn: null,
  tenantId: null,
  tenantCode: null,
  createdOn: '2026-10-19T02:00:00Z',
}
const INVITE = { id: '1c000000-0000-4000-8000-000000000001', token: 'cd'.repeat(32), path: `/invite/${'cd'.repeat(32)}`, expiresOn: '2026-11-02T03:30:00Z' }
/** Endpoints that need an active hospital (403 for an operator without one). */
const TENANT_SCOPED = /^\/api\/v1\/(patients|appointments|queue|branches|members|practitioners|schedules|slots|tenants\/current|invite-links)/
const session = () => fakeAuthClient({ session: fakeSession('operator@medicore.example') })

describe('Platform console', () => {
  it('lands a platform operator without a hospital on /platform, with the hospitals list', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(OPERATOR),
      'GET /api/v1/platform/tenants': () => json([LOTUS]),
      'GET /api/v1/platform/hospital-requests': () => json([REQUEST]),
    })
    renderWithProviders(<App />, { path: '/', auth: session() })
    const row = await screen.findByTestId('platform-tenant-row')
    expect(row).toHaveTextContent('Synthetic Lotus Clinic')
    expect(row).toHaveTextContent('Asia/Kolkata')
    expect(screen.getByRole('link', { name: /Hospital requests \(1 pending\)/ })).toBeInTheDocument()
    expect(screen.getByTestId('tenant-name')).toHaveTextContent('Platform console (no hospital access)')
    const primary = screen.getByRole('navigation', { name: 'Primary' })
    expect(within(primary).queryByRole('link', { name: 'Patients' })).not.toBeInTheDocument()
    expect(within(primary).getByRole('link', { name: 'Hospital requests' })).toBeInTheDocument()
    // No clinical or tenant-scoped endpoint is ever called for the operator (GET /branches was a 403).
    await waitFor(() => expect(calls.some((c) => c.path === '/api/v1/me/invitations')).toBe(true))
    expect(calls.filter((c) => TENANT_SCOPED.test(c.path)).map((c) => `${c.method} ${c.path}`)).toEqual([])
  })

  it('no tenant-scoped calls on any console page (requests, hospital detail) without a hospital', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(OPERATOR),
      'GET /api/v1/platform/tenants': () => json([LOTUS]),
      [`GET /api/v1/platform/tenants/${LOTUS.id}`]: () => json({ ...LOTUS, branches: [], admins: [], inviteLinks: [] }),
      'GET /api/v1/platform/hospital-requests': () => json([REQUEST]),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/platform/requests', auth: session() })
    expect(await screen.findByRole('button', { name: 'Approve Synthetic Orchid Hospital' })).toBeInTheDocument()
    await user.click(within(screen.getByRole('navigation', { name: 'Primary' })).getByRole('link', { name: 'Hospitals' }))
    await screen.findByTestId('platform-tenant-row')
    expect(calls.filter((c) => TENANT_SCOPED.test(c.path)).map((c) => `${c.method} ${c.path}`)).toEqual([])
  })

  it('sends search and status to the API', async () => {
    const calls = stubFetch({ 'GET /api/v1/me': () => json(OPERATOR), 'GET /api/v1/platform/tenants': () => json([]), 'GET /api/v1/platform/hospital-requests': () => json([]) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/platform', auth: session() })
    await user.type(await screen.findByLabelText('Search hospitals'), 'lot')
    await user.selectOptions(screen.getByLabelText('Status'), 'suspended')
    await waitFor(() =>
      expect(
        calls.some((c) => {
          const q = new URL(c.url, 'http://localhost').searchParams
          return c.path === '/api/v1/platform/tenants' && q.get('search') === 'lot' && q.get('status') === 'suspended'
        }),
      ).toBe(true),
    )
    expect(await screen.findByText('No hospitals match.')).toBeInTheDocument()
  })

  it('creates a hospital directly and shows the first-admin invite link once', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(OPERATOR),
      'GET /api/v1/platform/tenants': () => json([]),
      'GET /api/v1/platform/hospital-requests': () => json([]),
      'POST /api/v1/platform/tenants': () => json({ tenantId: LOTUS.id, invite: INVITE }, 201),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/platform', auth: session() })
    await user.click(await screen.findByRole('button', { name: 'Create hospital' }))
    const form = within(await screen.findByRole('form', { name: 'Create hospital' }))
    await user.type(form.getByLabelText('Hospital name'), 'Synthetic Lotus Clinic')
    expect(form.getByLabelText('Hospital code')).toHaveValue('synthetic-lotus-clinic')
    await user.type(form.getByLabelText('Hospital time zone'), 'Asia/Kolkata')
    await user.type(form.getByLabelText('First admin email'), 'asha@lotus.example')
    await user.click(form.getByRole('button', { name: 'Create hospital' }))
    expect(await screen.findByTestId('invite-link-url')).toHaveValue(`${window.location.origin}${INVITE.path}`)
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ name: 'Synthetic Lotus Clinic', code: 'synthetic-lotus-clinic', timeZone: 'Asia/Kolkata', adminEmail: 'asha@lotus.example' })
  })

  it('requires a time zone to create a hospital', async () => {
    const calls = stubFetch({ 'GET /api/v1/me': () => json(OPERATOR), 'GET /api/v1/platform/tenants': () => json([]), 'GET /api/v1/platform/hospital-requests': () => json([]) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/platform', auth: session() })
    await user.click(await screen.findByRole('button', { name: 'Create hospital' }))
    const form = within(await screen.findByRole('form', { name: 'Create hospital' }))
    await user.type(form.getByLabelText('Hospital name'), 'No Zone')
    await user.type(form.getByLabelText('First admin email'), 'a@nozone.example')
    await user.click(form.getByRole('button', { name: 'Create hospital' }))
    expect(await form.findByText('Choose the hospital time zone')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
  })

  it('approves a request with a tenant code and shows the invite link; rejects with a reason', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(OPERATOR),
      'GET /api/v1/platform/hospital-requests': () => json([REQUEST, { ...REQUEST, id: '5a000000-0000-4000-8000-000000000002', hospitalName: 'Spam Hospital' }]),
      [`POST /api/v1/platform/hospital-requests/${REQUEST.id}/approve`]: () => json({ tenantId: LOTUS.id, invite: INVITE }),
      'POST /api/v1/platform/hospital-requests/5a000000-0000-4000-8000-000000000002/reject': () => new Response(null, { status: 204 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/platform/requests', auth: session() })
    await user.click(await screen.findByRole('button', { name: 'Approve Synthetic Orchid Hospital' }))
    let dialog = await screen.findByRole('alertdialog')
    expect(within(dialog).getByLabelText('Hospital code')).toHaveValue('synthetic-orchid-hospital')
    expect(dialog).toHaveTextContent('Asia/Dubai')
    await user.click(within(dialog).getByRole('button', { name: 'Approve and create' }))
    expect(await screen.findByTestId('invite-link-notice')).toHaveTextContent('omar@orchid.example')
    expect(calls.find((c) => c.path.endsWith('/approve'))!.body).toEqual({ tenantCode: 'synthetic-orchid-hospital' })

    await user.click(screen.getByRole('button', { name: 'Reject Spam Hospital' }))
    dialog = await screen.findByRole('alertdialog')
    await user.click(within(dialog).getByRole('button', { name: 'Reject request' }))
    expect(await within(dialog).findByText(/Give a reason/)).toBeInTheDocument()
    await user.type(within(dialog).getByLabelText('Reason'), 'Not a real hospital')
    await user.click(within(dialog).getByRole('button', { name: 'Reject request' }))
    await waitFor(() => expect(calls.find((c) => c.path.endsWith('/reject'))?.body).toEqual({ reason: 'Not a real hospital' }))
  })

  it('suspends a hospital with a reason from its detail page', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(OPERATOR),
      [`GET /api/v1/platform/tenants/${LOTUS.id}`]: () => json({ tenant: LOTUS, history: [] }),
      [`POST /api/v1/platform/tenants/${LOTUS.id}/suspend`]: () => json({ ...LOTUS, status: 'suspended' }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/platform/hospitals/${LOTUS.id}`, auth: session() })
    const details = await screen.findByTestId('platform-tenant-details')
    expect(details).toHaveTextContent('Asia/Kolkata')
    expect(details).toHaveTextContent('19 Oct 2026, 03:30 UTC')
    await user.click(screen.getByRole('button', { name: 'Suspend hospital' }))
    const dialog = await screen.findByRole('alertdialog')
    await user.type(within(dialog).getByLabelText('Reason'), 'Unpaid synthetic invoice')
    await user.click(within(dialog).getByRole('button', { name: 'Suspend' }))
    await waitFor(() => expect(calls.find((c) => c.path.endsWith('/suspend'))?.body).toEqual({ reason: 'Unpaid synthetic invoice' }))
    expect(await screen.findByText(/is suspended/)).toBeInTheDocument()
  })

  it('keeps hospital staff out of the console (UX guard; the API answers 403 anyway)', async () => {
    const calls = stubFetch({ 'GET /api/v1/me': () => json(meFor()) })
    renderWithProviders(<App />, { path: '/platform', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByText('Only platform operators can open the platform console.')).toBeInTheDocument()
    expect(calls.some((c) => c.path.startsWith('/api/v1/platform'))).toBe(false)
    expect(screen.queryByRole('link', { name: 'Hospital requests' })).not.toBeInTheDocument()
  })
})
