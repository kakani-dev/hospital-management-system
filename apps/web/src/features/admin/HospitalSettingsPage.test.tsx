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

function routes(patch: (body: Record<string, unknown>) => Response) {
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /api/v1/tenants/current': () => json(tenant),
    'GET /api/v1/branches': () => json(branches),
    'PATCH /api/v1/tenants/current': (_u, init) => patch(JSON.parse(String(init.body))),
  })
}

const open = () => renderWithProviders(<App />, { path: '/admin/hospital', auth: fakeAuthClient({ session: fakeSession() }) })

describe('Hospital settings', () => {
  it('shows the zone and which branches follow it', async () => {
    routes(() => json(tenant))
    open()
    expect(await screen.findByLabelText('Hospital time zone')).toHaveValue('Asia/Kolkata')
    const summary = await screen.findByTestId('hospital-zone-branches')
    await waitFor(() => expect(summary).toHaveTextContent('Follow the hospital zoneAlpha Main'))
    expect(summary).toHaveTextContent('Alpha East (Asia/Dubai)')
  })

  it('validates the zone, asks before moving future bookings, then resends with confirmFutureBookings', async () => {
    let attempts = 0
    const calls = routes((body) =>
      ++attempts === 1
        ? json({ title: 'Conflict', status: 409, code: 'time_zone_has_future_bookings', futureBookings: 4 }, 409)
        : json({ ...tenant, timeZone: body.timeZone }),
    )
    const user = userEvent.setup()
    open()
    const zone = await screen.findByLabelText('Hospital time zone')
    await user.type(zone, 'Nowhere/Land')
    expect(screen.getByText('No time zone matches “Nowhere/Land”.')).toBeInTheDocument()
    await user.click(screen.getByLabelText('Hospital name'))
    expect(zone).toHaveValue('Asia/Kolkata')
    expect(screen.getByRole('button', { name: 'Save settings' })).toBeDisabled()
    await user.type(zone, 'Asia/Dubai')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(dialog).toHaveTextContent('4 future bookings')
    await user.click(within(dialog).getByRole('button', { name: 'Change time zone' }))
    await screen.findByText('Saved. The hospital time zone is now Asia/Dubai.')
    expect(calls.filter((c) => c.method === 'PATCH').map((c) => c.body)).toEqual([{ timeZone: 'Asia/Dubai' }, { timeZone: 'Asia/Dubai', confirmFutureBookings: true }])
  })

  it('cancelling the confirmation saves nothing', async () => {
    const calls = routes(() => json({ title: 'Conflict', status: 409, code: 'time_zone_has_future_bookings', futureBookings: 1 }, 409))
    const user = userEvent.setup()
    open()
    const zone = await screen.findByLabelText('Hospital time zone')
    await user.clear(zone)
    await user.type(zone, 'Asia/Dubai')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
    expect(calls.filter((c) => c.method === 'PATCH')).toHaveLength(1)
  })

  it('explains time_zone_locked and sends only the changed name', async () => {
    let n = 0
    const calls = routes(() => (++n === 1 ? json({ title: 'Conflict', status: 409, code: 'time_zone_locked' }, 409) : json({ ...tenant, name: 'Renamed' })))
    const user = userEvent.setup()
    open()
    const zone = await screen.findByLabelText('Hospital time zone')
    await user.clear(zone)
    await user.type(zone, 'Asia/Dubai')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(await screen.findByText(/Change the time zone after the day closes\./)).toBeInTheDocument()
    await user.clear(zone)
    await user.type(zone, 'Asia/Kolkata')
    await user.clear(screen.getByLabelText('Hospital name'))
    await user.type(screen.getByLabelText('Hospital name'), 'Renamed')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    await screen.findByText('Saved.')
    expect(calls.filter((c) => c.method === 'PATCH')[1]!.body).toEqual({ name: 'Renamed' })
  })
})
