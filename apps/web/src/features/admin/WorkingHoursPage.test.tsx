import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, branchesResponse, practitioners, schedules, today } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const deleted = { ...schedules[0]!, id: 's-del', weekday: 7, isDeleted: true }

function routes(extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': () => json(practitioners),
    'GET /api/v1/schedules': (url) => json([...schedules, deleted].filter((s) => s.branchId === url.searchParams.get('branchId'))),
    ...extra,
  })
}

const open = () => renderWithProviders(<App />, { path: `/admin/working-hours?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })

describe('Working hours admin', () => {
  it('lists the branch’s weekly hours (deleted rows hidden until asked) with includeDeleted', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    const rows = await screen.findAllByTestId('schedule-row')
    expect(rows).toHaveLength(5)
    expect(rows[0]).toHaveTextContent('Dr. Rao (synthetic)')
    expect(rows[0]).toHaveTextContent('Monday')
    expect(rows[0]).toHaveTextContent('09:00–13:00')
    expect(screen.getByText('Times are branch-local (Asia/Kolkata).')).toBeInTheDocument()
    const url = new URL(calls.find((c) => c.path === '/api/v1/schedules')!.url, 'http://x')
    expect(url.searchParams.get('includeDeleted')).toBe('true')
    await user.click(screen.getByLabelText('Show deleted'))
    expect(await screen.findByRole('button', { name: 'Restore Dr. Rao (synthetic) on Sunday 09:00–13:00' })).toBeInTheDocument()
  })

  it('adds hours from the branch’s today, validates them, and explains an overlap', async () => {
    let attempts = 0
    const calls = routes({
      'POST /api/v1/schedules': (_u, init) =>
        ++attempts === 1
          ? json({ title: 'Conflict', status: 409, code: 'schedule_overlap' }, 409)
          : json({ id: 'new', isActive: true, ...JSON.parse(String(init.body)) }, 201),
    })
    const user = userEvent.setup()
    open()
    await screen.findAllByTestId('schedule-row')
    expect(screen.getByLabelText('Valid from')).toHaveValue(today())
    await user.selectOptions(screen.getByLabelText('Practitioner'), DR_RAO)
    await user.selectOptions(screen.getByLabelText('Weekday'), '6')
    await user.clear(screen.getByLabelText('End time'))
    await user.type(screen.getByLabelText('End time'), '08:00')
    await user.click(screen.getByRole('button', { name: 'Add hours' }))
    expect(await screen.findByText('End must be after start')).toBeInTheDocument()
    await user.clear(screen.getByLabelText('End time'))
    await user.type(screen.getByLabelText('End time'), '12:00')
    await user.click(screen.getByRole('button', { name: 'Add hours' }))
    expect(await screen.findByText('These hours overlap another active schedule of this practitioner on that weekday.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Add hours' }))
    await screen.findByText('Added Dr. Rao (synthetic) on Saturday 09:00–12:00.')
    expect(calls.filter((c) => c.method === 'POST')[1]!.body).toEqual({
      practitionerId: DR_RAO,
      branchId: ALPHA_MAIN,
      weekday: 6,
      startTime: '09:00',
      endTime: '12:00',
      slotMinutes: 15,
      validFrom: today(),
      validTo: null,
    })
  })

  it('edits hours in the drawer and deactivates a row', async () => {
    const first = schedules[0]!
    const calls = routes({ [`PATCH /api/v1/schedules/${first.id}`]: (_u, init) => json({ ...first, ...JSON.parse(String(init.body)) }) })
    const user = userEvent.setup()
    open()
    await user.click(await screen.findByRole('button', { name: 'Edit Dr. Rao (synthetic) on Monday 09:00–13:00' }))
    const drawer = await screen.findByTestId('schedule-drawer')
    await user.clear(within(drawer).getByLabelText('Slot length (minutes)'))
    await user.type(within(drawer).getByLabelText('Slot length (minutes)'), '20')
    await user.click(within(drawer).getByRole('button', { name: 'Save' }))
    await screen.findByText('Saved Dr. Rao (synthetic) on Monday 09:00–13:00.')
    await user.click(screen.getByRole('button', { name: 'Deactivate Dr. Rao (synthetic) on Monday 09:00–13:00' }))
    await screen.findByText('Deactivated Dr. Rao (synthetic) on Monday 09:00–13:00.')
    const patches = calls.filter((c) => c.method === 'PATCH').map((c) => c.body)
    expect(patches).toEqual([{ weekday: 1, startTime: '09:00', endTime: '13:00', slotMinutes: 20, validFrom: '2026-01-01' }, { isActive: false }])
  })
})
