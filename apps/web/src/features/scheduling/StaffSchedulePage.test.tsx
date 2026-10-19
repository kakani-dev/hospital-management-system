import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { addDays, startOfWeek } from '../../lib/dates'
import { branchesResponse, practitioners, schedules, today } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

function routes(roles = ['viewer']) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': () => json(practitioners),
    'GET /api/v1/schedules': (url) => json(schedules.filter((s) => s.branchId === url.searchParams.get('branchId'))),
  })
}

describe('StaffSchedulePage', () => {
  it('shows each practitioner’s weekly hours at the selected branch', async () => {
    const calls = routes()
    renderWithProviders(<App />, { path: `/schedules?branch=${ALPHA_MAIN}&date=2026-10-07`, auth: fakeAuthClient({ session: fakeSession() }) })

    const row = await screen.findByTestId('schedule-row')
    expect(within(row).getByRole('rowheader')).toHaveTextContent('Dr. Rao (synthetic)')
    const cells = within(row).getAllByTestId('schedule-cell')
    expect(cells.map((c) => c.dataset.date)).toEqual(['2026-10-05', '2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09', '2026-10-10', '2026-10-11'])
    expect(cells[0]).toHaveTextContent('09:00–13:00')
    expect(cells[0]).toHaveTextContent('15-min slots')
    expect(cells[5]).toHaveTextContent('Off')
    // the zone label waits for the branch zone (never the workstation's)
    await waitFor(() => expect(screen.getByTestId('calendar-range')).toHaveTextContent('Asia/Kolkata'))
    expect(calls.find((c) => c.path === '/api/v1/schedules')!.url).toBe(`/api/v1/schedules?branchId=${ALPHA_MAIN}`)
  })

  it('switches branch and week from the toolbar (any member can view)', async () => {
    const calls = routes(['pharmacist'])
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/schedules', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('schedule-row')
    expect(screen.getByRole('link', { name: 'Schedules' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Appointments' })).not.toBeInTheDocument() // pharmacist is not REG_READ

    await user.selectOptions(screen.getByLabelText('Showing branch'), ALPHA_EAST)
    await waitFor(() => expect(within(screen.getByTestId('schedule-row')).getByRole('rowheader')).toHaveTextContent('Dr. Iyer'))
    expect(calls.filter((c) => c.path === '/api/v1/schedules').at(-1)!.url).toContain(ALPHA_EAST)

    const firstDay = () => screen.getAllByTestId('schedule-cell')[0]!.dataset.date
    expect(firstDay()).toBe(startOfWeek(today()))
    await user.click(screen.getByRole('button', { name: 'Next week' }))
    expect(firstDay()).toBe(addDays(startOfWeek(today()), 7))
  })

  it('shows an empty state when the branch has no schedules', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['doctor'])),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/practitioners': () => json(practitioners),
      'GET /api/v1/schedules': () => json([]),
    })
    renderWithProviders(<App />, { path: '/schedules', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('schedules-empty')).toBeInTheDocument()
  })
})
