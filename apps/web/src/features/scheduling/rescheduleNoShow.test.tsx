import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { addDays } from '../../lib/dates'
import { DR_RAO, appointment, at, branchesResponse, paged, practitionersApi, schedules, today } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const APPT = 'ap000000-0000-4000-8000-000000000001'

function routes(appt: ReturnType<typeof appointment>, extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': (url) => json(schedules.filter((s) => s.branchId === url.searchParams.get('branchId'))),
    'GET /api/v1/appointments': () => json(paged([appt])),
    ...extra,
  })
}

const open = (date: string) => renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}&date=${date}`, auth: fakeAuthClient({ session: fakeSession() }) })

describe('Reschedule and no-show on the calendar', () => {
  it('moves a booked appointment to a free slot via POST /reschedule (branch-local slot times)', async () => {
    const tomorrow = addDays(today(), 1)
    const slot = { practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(tomorrow, '11:00'), endsAt: at(tomorrow, '11:15') }
    const appt = appointment({ startsAt: at(tomorrow, '09:30'), endsAt: at(tomorrow, '09:45') })
    let conflict = true
    const calls = routes(appt, {
      'GET /api/v1/slots': () => json([slot]),
      [`POST /api/v1/appointments/${APPT}/reschedule`]: () => {
        if (conflict) {
          conflict = false
          return json({ title: 'Conflict', status: 409, code: 'appointment_overlap' }, 409)
        }
        return json({ ...appt, startsAt: slot.startsAt, endsAt: slot.endsAt })
      },
    })
    const user = userEvent.setup()
    open(tomorrow)
    const item = await screen.findByTestId('appointment')
    // Not started yet: no "no-show" action.
    expect(within(item).queryByRole('button', { name: 'Mark no-show' })).not.toBeInTheDocument()
    await user.click(within(item).getByRole('button', { name: 'Reschedule' }))
    const drawer = await screen.findByTestId('reschedule-drawer')
    expect(within(drawer).getByTestId('reschedule-current')).toHaveTextContent('09:30')
    expect(within(drawer).getByLabelText('New date')).toHaveValue(tomorrow)
    await user.click(await within(drawer).findByText('11:00'))
    await user.click(within(drawer).getByRole('button', { name: 'Confirm new time' }))
    expect(await within(drawer).findByText('That slot was just taken. Pick another slot.')).toBeInTheDocument()
    await user.click(await within(drawer).findByText('11:00'))
    await user.click(within(drawer).getByRole('button', { name: 'Confirm new time' }))
    await screen.findByText(/^Moved Asha Synthetic-Alpha to .* at 11:00\.$/)
    const posts = calls.filter((c) => c.method === 'POST').map((c) => c.body)
    // Same practitioner: practitionerId is omitted.
    expect(posts).toEqual([
      { startsAt: slot.startsAt, endsAt: slot.endsAt },
      { startsAt: slot.startsAt, endsAt: slot.endsAt },
    ])
    await waitFor(() => expect(screen.queryByTestId('reschedule-drawer')).not.toBeInTheDocument())
  })

  it('offers "Mark no-show" only once a booked appointment has started and confirms first', async () => {
    const yesterday = addDays(today(), -1)
    const appt = appointment({ startsAt: at(yesterday, '09:30'), endsAt: at(yesterday, '09:45') })
    const calls = routes(appt, {
      [`POST /api/v1/appointments/${APPT}/no-show`]: () => json({ ...appt, status: 'no_show' }),
    })
    const user = userEvent.setup()
    open(yesterday)
    const item = await screen.findByTestId('appointment')
    await user.click(within(item).getByRole('button', { name: 'Mark no-show' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(dialog).toHaveTextContent('Asha Synthetic-Alpha did not come to the 09:30 appointment')
    await user.click(within(dialog).getByRole('button', { name: 'Mark no-show' }))
    await screen.findByText('Asha Synthetic-Alpha was marked as a no-show.')
    expect(calls.filter((c) => c.method === 'POST').map((c) => c.path)).toEqual([`/api/v1/appointments/${APPT}/no-show`])
  })

  it('explains a 409 invalid_transition from no-show', async () => {
    const yesterday = addDays(today(), -1)
    const appt = appointment({ startsAt: at(yesterday, '09:30'), endsAt: at(yesterday, '09:45') })
    routes(appt, {
      [`POST /api/v1/appointments/${APPT}/no-show`]: () => json({ title: 'Conflict', status: 409, code: 'invalid_transition' }, 409),
    })
    const user = userEvent.setup()
    open(yesterday)
    await user.click(within(await screen.findByTestId('appointment')).getByRole('button', { name: 'Mark no-show' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Mark no-show' }))
    expect(await screen.findByText('Only booked appointments that have started can be marked as no-show.')).toBeInTheDocument()
  })

  it('billing sees neither action', async () => {
    const appt = appointment()
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['billing'])),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/practitioners': practitionersApi,
      'GET /api/v1/appointments': () => json(paged([appt])),
    })
    open(today())
    const item = await screen.findByTestId('appointment')
    expect(within(item).queryByRole('button', { name: 'Reschedule' })).not.toBeInTheDocument()
    expect(within(item).queryByRole('button', { name: 'Mark no-show' })).not.toBeInTheDocument()
  })
})
