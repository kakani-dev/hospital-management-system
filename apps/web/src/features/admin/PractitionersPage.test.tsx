import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_IYER, DR_RAO } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const DELETED = 'd0000000-0000-4000-8000-000000000009'
const USER = '0a000000-0000-4000-8000-000000000005'
const list = [
  { id: DR_RAO, userId: null, displayName: 'Dr. Rao', specialty: 'General medicine', isActive: true, isDeleted: false },
  { id: DR_IYER, userId: USER, displayName: 'Dr. Iyer', specialty: null, isActive: false, isDeleted: false },
  { id: DELETED, userId: null, displayName: 'Dr. Gone', specialty: null, isActive: true, isDeleted: true },
]
const members = [{ id: 'm1', userId: USER, email: 'iyer@alpha.example', displayName: null, role: 'doctor', branchId: null, branchName: null, status: 'active' }]

function routes(extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /api/v1/practitioners': () => json(list),
    'GET /api/v1/members': () => json(members),
    'POST /api/v1/practitioners': (_u, init) => json({ id: 'new', userId: null, isActive: true, ...JSON.parse(String(init.body)) }, 201),
    ...extra,
  })
}

const open = () => renderWithProviders(<App />, { path: '/admin/practitioners', auth: fakeAuthClient({ session: fakeSession() }) })

describe('Practitioners admin', () => {
  it('lists live practitioners (deleted ones behind "Show deleted") from the includeDeleted list', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    const rows = await screen.findAllByTestId('practitioner-row')
    expect(rows.map((r) => r.dataset.status)).toEqual(['active', 'inactive'])
    expect(rows[1]).toHaveTextContent('iyer@alpha.example')
    const url = new URL(calls.find((c) => c.path === '/api/v1/practitioners')!.url, 'http://x')
    expect(url.searchParams.get('includeDeleted')).toBe('true')
    expect(url.searchParams.get('activeOnly')).toBe('false')
    await user.click(screen.getByLabelText('Show deleted'))
    expect(await screen.findByRole('button', { name: 'Restore Dr. Gone' })).toBeInTheDocument()
  })

  it('adds a practitioner (blank specialty → null, unlinked → no userId)', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    await screen.findAllByTestId('practitioner-row')
    await user.click(screen.getByRole('button', { name: 'Add practitioner' }))
    expect(await screen.findByText('Name is required')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Display name'), 'Dr. New')
    await user.click(screen.getByRole('button', { name: 'Add practitioner' }))
    await screen.findByText('Dr. New added. Add working hours so patients can be booked.')
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ displayName: 'Dr. New', specialty: null })
  })

  it('edits in the drawer and unlinks the staff account', async () => {
    const calls = routes({ [`PATCH /api/v1/practitioners/${DR_IYER}`]: (_u, init) => json({ ...list[1], ...JSON.parse(String(init.body)), userId: null }) })
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByRole('button', { name: 'Edit Dr. Iyer' }))
    const drawer = await screen.findByTestId('practitioner-drawer')
    await user.type(within(drawer).getByLabelText('Specialty (optional)'), 'Paediatrics')
    await user.selectOptions(within(drawer).getByLabelText('Staff account (optional)'), '')
    await user.click(within(drawer).getByRole('button', { name: 'Save' }))
    await screen.findByText('Dr. Iyer saved.')
    expect(calls.find((c) => c.method === 'PATCH')!.body).toEqual({ displayName: 'Dr. Iyer', specialty: 'Paediatrics', unlinkUser: true })
  })

  it('confirms a delete and explains the 409 for open appointments', async () => {
    routes({ [`DELETE /api/v1/practitioners/${DR_RAO}`]: () => json({ title: 'Conflict', status: 409, code: 'invalid_state' }, 409) })
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByRole('button', { name: 'Delete Dr. Rao' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Delete' }))
    expect(await screen.findByText('Dr. Rao has open appointments. Cancel or reschedule them first.')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
  })

  it('restores a deleted practitioner', async () => {
    const calls = routes({ [`POST /api/v1/practitioners/${DELETED}/restore`]: () => json(null, 204) })
    const user = userEvent.setup()
    open()
    await screen.findAllByTestId('practitioner-row')
    await user.click(screen.getByLabelText('Show deleted'))
    await user.click(await screen.findByRole('button', { name: 'Restore Dr. Gone' }))
    await screen.findByText('Dr. Gone was restored as inactive. Activate them to make them bookable again.')
    expect(calls.filter((c) => c.method === 'POST').map((c) => c.path)).toEqual([`/api/v1/practitioners/${DELETED}/restore`])
  })

  it('is admin-only', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meWithRoles(['receptionist'])) })
    open()
    expect(await screen.findByTestId('forbidden')).toHaveTextContent(/does not include access/i)
  })
})
