import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA, ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const tenant = { id: ALPHA, code: 'alpha', name: 'Demo Alpha Hospital', activeBranchId: null, roles: ['tenant_admin'], timeZone: 'Asia/Kolkata' }
const branches = [
  { id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: 'Asia/Kolkata', timezoneOverride: null, isActive: true },
  { id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: 'Asia/Dubai', timezoneOverride: 'Asia/Dubai', isActive: true },
]

function routes(patch: (body: unknown) => Response = () => json(branches[1])) {
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /api/v1/tenants/current': () => json(tenant),
    'GET /api/v1/branches': () => json(branches),
    'POST /api/v1/branches': (_u, init) => json({ ...JSON.parse(String(init.body)), id: 'new', timezone: 'Asia/Kolkata', timezoneOverride: null, isActive: true }, 201),
    [`PATCH /api/v1/branches/${ALPHA_EAST}`]: (_u, init) => patch(JSON.parse(String(init.body))),
  })
}

const open = () => renderWithProviders(<App />, { path: '/admin/branches', auth: fakeAuthClient({ session: fakeSession() }) })

describe('Branches page: time zone', () => {
  it('defaults to the hospital zone and omits the override', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    const inherit = await screen.findByLabelText('Use hospital time zone (Asia/Kolkata)')
    expect(inherit).toBeChecked()
    expect(screen.queryByLabelText('Time zone')).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Code'), 'north')
    await user.type(screen.getByLabelText('Branch name'), 'North')
    await user.click(screen.getByRole('button', { name: 'Add branch' }))
    await screen.findByText('Branch North created.')
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ code: 'north', name: 'North' })
  })

  it('sends an explicit override when the box is cleared, and validates it', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByLabelText('Use hospital time zone (Asia/Kolkata)'))
    await user.type(screen.getByLabelText('Code'), 'gulf')
    await user.type(screen.getByLabelText('Branch name'), 'Gulf')
    await user.type(screen.getByLabelText('Time zone'), 'Mars/Olympus')
    await user.click(screen.getByRole('button', { name: 'Add branch' }))
    expect(await screen.findByText('Use an IANA time zone, e.g. Asia/Kolkata')).toBeInTheDocument()
    await user.clear(screen.getByLabelText('Time zone'))
    await user.type(screen.getByLabelText('Time zone'), 'Asia/Dubai')
    await user.click(screen.getByRole('button', { name: 'Add branch' }))
    await screen.findByText('Branch Gulf created.')
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ code: 'gulf', name: 'Gulf', timezone: 'Asia/Dubai' })
  })

  it('shows inherited vs overridden zones and confirms future bookings before inheriting', async () => {
    let attempts = 0
    const calls = routes(() =>
      ++attempts === 1
        ? json({ title: 'Conflict', status: 409, code: 'time_zone_has_future_bookings', futureBookings: 3 }, 409)
        : json({ ...branches[1], timezone: 'Asia/Kolkata', timezoneOverride: null }),
    )
    const user = userEvent.setup()
    open()
    const rows = await screen.findAllByTestId('branch-row')
    expect(rows[0]).toHaveTextContent('Asia/Kolkata (hospital zone)')
    expect(within(rows[0]!).queryByRole('button', { name: /hospital time zone/ })).not.toBeInTheDocument()
    await user.click(within(rows[1]!).getByRole('button', { name: 'Use the hospital time zone at Alpha East' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(dialog).toHaveTextContent('3 future bookings')
    await user.click(within(dialog).getByRole('button', { name: 'Change time zone' }))
    await screen.findByText('Alpha East now uses the hospital time zone.')
    const patches = calls.filter((c) => c.method === 'PATCH').map((c) => c.body)
    expect(patches).toEqual([{ inheritTimezone: true }, { inheritTimezone: true, confirmFutureBookings: true }])
    await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
  })

  it('edits a branch: an own zone for a branch that followed the hospital, confirming future bookings', async () => {
    const main = branches[0]!
    let attempts = 0
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/tenants/current': () => json(tenant),
      'GET /api/v1/branches': () => json(branches),
      [`PATCH /api/v1/branches/${ALPHA_MAIN}`]: (_u, init) =>
        ++attempts === 1
          ? json({ title: 'Conflict', status: 409, code: 'time_zone_has_future_bookings', futureBookings: 2 }, 409)
          : json({ ...main, ...JSON.parse(String(init.body)), timezoneOverride: 'Asia/Dubai' }),
    })
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByRole('button', { name: 'Edit Alpha Main' }))
    const drawer = await screen.findByTestId('branch-drawer')
    const follow = within(drawer).getByLabelText('Use hospital time zone (Asia/Kolkata)')
    expect(follow).toBeChecked()
    await user.click(follow)
    await user.clear(within(drawer).getByLabelText('Branch time zone'))
    await user.type(within(drawer).getByLabelText('Branch time zone'), 'Asia/Dubai')
    await user.clear(within(drawer).getByLabelText('Branch name'))
    await user.type(within(drawer).getByLabelText('Branch name'), 'Alpha Main Campus')
    await user.click(within(drawer).getByRole('button', { name: 'Save branch' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(dialog).toHaveTextContent('2 future bookings')
    expect(dialog).toHaveTextContent('the new time zone (Asia/Dubai)')
    await user.click(within(dialog).getByRole('button', { name: 'Change time zone' }))
    await screen.findByText('Alpha Main Campus saved.')
    expect(calls.filter((c) => c.method === 'PATCH').map((c) => c.body)).toEqual([
      { name: 'Alpha Main Campus', timezone: 'Asia/Dubai' },
      { name: 'Alpha Main Campus', timezone: 'Asia/Dubai', confirmFutureBookings: true },
    ])
  })

  it('edits a branch override back to the hospital zone, or changes only the name', async () => {
    const calls = routes((body) => json({ ...branches[1], ...(body as object) }))
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByRole('button', { name: 'Edit Alpha East' }))
    let drawer = await screen.findByTestId('branch-drawer')
    expect(within(drawer).getByLabelText('Branch time zone')).toHaveValue('Asia/Dubai')
    await user.clear(within(drawer).getByLabelText('Branch name'))
    await user.type(within(drawer).getByLabelText('Branch name'), 'Alpha East Clinic')
    await user.click(within(drawer).getByRole('button', { name: 'Save branch' }))
    await screen.findByText('Alpha East Clinic saved.')
    await waitFor(() => expect(screen.queryByTestId('branch-drawer')).not.toBeInTheDocument())
    await user.click(screen.getByRole('button', { name: 'Edit Alpha East' }))
    drawer = await screen.findByTestId('branch-drawer')
    await user.click(within(drawer).getByLabelText('Use hospital time zone (Asia/Kolkata)'))
    expect(within(drawer).queryByLabelText('Branch time zone')).not.toBeInTheDocument()
    await user.click(within(drawer).getByRole('button', { name: 'Save branch' }))
    await waitFor(() => expect(calls.filter((c) => c.method === 'PATCH')).toHaveLength(2))
    expect(calls.filter((c) => c.method === 'PATCH').map((c) => c.body)).toEqual([{ name: 'Alpha East Clinic' }, { inheritTimezone: true }])
  })
})
