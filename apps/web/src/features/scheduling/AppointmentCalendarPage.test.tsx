import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { addDays, startOfWeek } from '../../lib/dates'
import {
  DR_RAO,
  PATIENT_ID,
  appointment,
  at,
  branchesResponse,
  paged,
  patientDetail,
  practitionersApi,
  practitionersApiWithoutBranchFilter,
  schedules,
  today,
} from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

function routes(roles: string[], extra: Parameters<typeof stubFetch>[0] = {}, branchId: string | null = null) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, branchId)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': (url) => json(schedules.filter((s) => s.branchId === url.searchParams.get('branchId'))),
    'GET /api/v1/appointments': () => json(paged([appointment()])),
    ...extra,
  })
}

describe('AppointmentCalendarPage', () => {
  it('day view: requests the branch-local day as an instant range and shows names, times and status', async () => {
    const calls = routes(['billing'])
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })

    const item = await screen.findByTestId('appointment')
    await waitFor(() => expect(item).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(item).toHaveTextContent('09:30–09:45')
    expect(item).toHaveTextContent('Dr. Rao (synthetic)')
    expect(item).toHaveTextContent('Booked')
    expect(screen.getByRole('button', { name: 'Day', pressed: true })).toBeInTheDocument()
    // billing reads the calendar but cannot book or cancel
    expect(screen.queryByRole('button', { name: 'Book appointment' })).not.toBeInTheDocument()
    expect(within(item).queryByRole('button', { name: 'Cancel appointment' })).not.toBeInTheDocument()

    const url = new URL(calls.find((c) => c.path === '/api/v1/appointments')!.url, 'http://x')
    expect(url.searchParams.get('branchId')).toBe(ALPHA_MAIN)
    expect(url.searchParams.get('from')).toBe(at(today(), '00:00'))
    expect(url.searchParams.get('to')).toBe(at(addDays(today(), 1), '00:00'))
    expect(url.searchParams.get('pageSize')).toBe('100')
    // API v2: names come from the embedded patient summary — no per-patient fetches
    expect(calls.filter((c) => c.path.startsWith('/api/v1/patients/'))).toEqual([])
  })

  it('falls back to GET /patients/{id} only for rows that lack the embedded summary (older API)', async () => {
    const OTHER = 'aa000000-0000-4000-8000-000000000002'
    const calls = routes(['billing'], {
      'GET /api/v1/appointments': () =>
        json(paged([appointment(), appointment({ id: 'a-legacy', patientId: OTHER, patient: undefined, startsAt: at(today(), '10:00'), endsAt: at(today(), '10:15') })])),
      [`GET /api/v1/patients/${OTHER}`]: () => json({ ...patientDetail, id: OTHER, mrn: 'ALP-0002', firstName: 'Bina' }),
    })
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })

    await waitFor(() => expect(screen.getAllByTestId('appointment').map((a) => a.textContent)).toEqual([expect.stringContaining('Synthetic-Alpha, Asha'), expect.stringContaining('Synthetic-Alpha, Bina')]))
    expect(calls.filter((c) => c.path.startsWith('/api/v1/patients/')).map((c) => c.path)).toEqual([`/api/v1/patients/${OTHER}`])
  })

  it('offers practitioners from GET /practitioners?branchId= (API v2)', async () => {
    const calls = routes(['receptionist'], {}, ALPHA_MAIN)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const select = within(screen.getByRole('form', { name: 'Book appointment' })).getByLabelText('Practitioner')
    await waitFor(() => expect(within(select).getAllByRole('option').map((o) => o.textContent)).toEqual(['Select a practitioner…', 'Dr. Rao (synthetic) (General medicine)']))
    expect(calls.some((c) => c.path === '/api/v1/practitioners' && new URL(c.url, 'http://x').searchParams.get('branchId') === ALPHA_MAIN)).toBe(true)
    // the branch list is authoritative: no schedule download just to filter practitioners
    expect(calls.some((c) => c.path === '/api/v1/schedules')).toBe(false)
  })

  it('an older API that rejects ?branchId= (400) falls back to practitioners scheduled at the branch', async () => {
    const calls = routes(['receptionist'], { 'GET /api/v1/practitioners': practitionersApiWithoutBranchFilter }, ALPHA_MAIN)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const select = within(screen.getByRole('form', { name: 'Book appointment' })).getByLabelText('Practitioner')
    // tenant-wide list has Rao and Iyer; only Rao has a schedule at Alpha Main
    await waitFor(() => expect(within(select).getAllByRole('option').map((o) => o.textContent)).toEqual(['Select a practitioner…', 'Dr. Rao (synthetic) (General medicine)']))
    expect(calls.some((c) => c.path === '/api/v1/schedules' && new URL(c.url, 'http://x').searchParams.get('branchId') === ALPHA_MAIN)).toBe(true)
  })

  it('week view: seven branch-local days, Monday first, and appointments land on their day', async () => {
    const monday = startOfWeek(today())
    const calls = routes(['doctor'], {
      'GET /api/v1/appointments': () =>
        json(paged([appointment({ id: 'a-mon', startsAt: at(monday, '09:00'), endsAt: at(monday, '09:15') }), appointment({ id: 'a-wed', startsAt: at(addDays(monday, 2), '23:45'), endsAt: at(addDays(monday, 3), '00:00') })])),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Week' }))

    const days = await screen.findAllByTestId('calendar-day')
    expect(days.map((d) => d.dataset.date)).toEqual(Array.from({ length: 7 }, (_, i) => addDays(monday, i)))
    await waitFor(() => expect(within(days[0]!).getAllByTestId('appointment')).toHaveLength(1))
    // 23:45 IST on Wednesday is still Wednesday in the branch zone (it is 18:15 UTC)
    expect(within(days[2]!).getAllByTestId('appointment')).toHaveLength(1)
    const url = new URL(calls.filter((c) => c.path === '/api/v1/appointments').at(-1)!.url, 'http://x')
    expect(url.searchParams.get('from')).toBe(at(monday, '00:00'))
    expect(url.searchParams.get('to')).toBe(at(addDays(monday, 7), '00:00'))
  })

  it('books: practitioner, free slot and patient → POST /appointments, then shows the booking', async () => {
    const d = today()
    const slot = { practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(d, '23:00'), endsAt: at(d, '23:15') }
    const calls = routes(
      ['receptionist'],
      {
        'GET /api/v1/slots': () => json([slot]),
        'POST /api/v1/patients/search': () => json({ items: [patientDetail], page: 1, pageSize: 25, totalCount: 1 }),
        'POST /api/v1/appointments': (_u, init) => json(appointment({ id: 'new', ...JSON.parse(String(init.body)) }), 201),
      },
      ALPHA_MAIN,
    )
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const form = screen.getByRole('form', { name: 'Book appointment' })

    // Only practitioners working at the branch are offered (GET /practitioners?branchId=)
    const practitionerSelect = within(form).getByLabelText('Practitioner')
    await waitFor(() => expect(within(practitionerSelect).getAllByRole('option').map((o) => o.textContent)).toEqual(['Select a practitioner…', 'Dr. Rao (synthetic) (General medicine)']))
    await user.selectOptions(practitionerSelect, DR_RAO)
    await user.click(await within(form).findByRole('radio', { name: '23:00' }))
    await user.type(within(form).getByLabelText('Find patient'), 'Asha')
    await user.click(await within(form).findByRole('option', { name: /Synthetic-Alpha, Asha/ }))
    await user.type(within(form).getByLabelText('Reason (optional)'), 'Follow-up')
    await user.click(within(form).getByRole('button', { name: 'Confirm booking' }))

    expect(await screen.findByText(/Booked Asha Synthetic-Alpha with Dr. Rao \(synthetic\) on .* at 23:00\./)).toBeInTheDocument()
    expect(screen.queryByRole('form', { name: 'Book appointment' })).not.toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/appointments')!.body).toEqual({
      branchId: ALPHA_MAIN,
      practitionerId: DR_RAO,
      patientId: PATIENT_ID,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      reason: 'Follow-up',
    })
    const slotUrl = new URL(calls.find((c) => c.path === '/api/v1/slots')!.url, 'http://x')
    expect(Object.fromEntries(slotUrl.searchParams)).toEqual({ branchId: ALPHA_MAIN, practitionerId: DR_RAO, from: d, to: d })
    expect(calls.filter((c) => c.path === '/api/v1/patients/search').every((c) => c.method === 'POST' && !c.url.includes('Asha'))).toBe(true)
  })

  it('a 409 appointment_overlap keeps the form open, explains the conflict and reloads the slots', async () => {
    const d = today()
    const slot = { practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(d, '23:00'), endsAt: at(d, '23:15') }
    const calls = routes(['tenant_admin'], {
      'GET /api/v1/slots': () => json([slot]),
      'POST /api/v1/patients/search': () => json({ items: [patientDetail], page: 1, pageSize: 25, totalCount: 1 }),
      'POST /api/v1/appointments': () => json({ title: 'Conflict', status: 409, code: 'appointment_overlap' }, 409),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const form = screen.getByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(form).getAllByRole('option').length).toBeGreaterThan(1))
    await user.selectOptions(within(form).getByLabelText('Practitioner'), DR_RAO)
    await user.click(await within(form).findByRole('radio', { name: '23:00' }))
    await user.type(within(form).getByLabelText('Find patient'), 'Asha')
    await user.click(await within(form).findByRole('option', { name: /Synthetic-Alpha/ }))
    const slotFetches = calls.filter((c) => c.path === '/api/v1/slots').length
    await user.click(within(form).getByRole('button', { name: 'Confirm booking' }))

    expect(await within(form).findByRole('alert')).toHaveTextContent('That slot was just booked for this practitioner. Pick another slot.')
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/slots').length).toBeGreaterThan(slotFetches))
    expect(within(form).getByRole('radio', { name: '23:00' })).not.toBeChecked()
  })

  it('a 404 on booking (patient deleted meanwhile, contract v4) explains instead of failing silently', async () => {
    const d = today()
    routes(
      ['receptionist'],
      {
        'GET /api/v1/slots': () => json([{ practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(d, '23:00'), endsAt: at(d, '23:15') }]),
        'POST /api/v1/patients/search': () => json({ items: [patientDetail], page: 1, pageSize: 25, totalCount: 1 }),
        'POST /api/v1/appointments': () => json({ title: 'Not found', status: 404, code: 'not_found' }, 404),
      },
      ALPHA_MAIN,
    )
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const form = screen.getByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(form).getAllByRole('option').length).toBeGreaterThan(1))
    await user.selectOptions(within(form).getByLabelText('Practitioner'), DR_RAO)
    await user.click(await within(form).findByRole('radio', { name: '23:00' }))
    await user.type(within(form).getByLabelText('Find patient'), 'Asha')
    await user.click(await within(form).findByRole('option', { name: /Synthetic-Alpha/ }))
    await user.click(within(form).getByRole('button', { name: 'Confirm booking' }))
    expect(await within(form).findByRole('alert')).toHaveTextContent('can no longer be booked')
  })

  it('requires practitioner, slot and patient before posting', async () => {
    const calls = routes(['receptionist'], {}, ALPHA_MAIN)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    await user.click(screen.getByRole('button', { name: 'Confirm booking' }))
    expect(await screen.findByText('Choose a practitioner, a free slot and a patient.')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST' && c.path === '/api/v1/appointments')).toBe(false)
  })

  it('cancels a booked appointment', async () => {
    const calls = routes(['receptionist'], { 'POST /api/v1/appointments/ap000000-0000-4000-8000-000000000001/cancel': () => json(appointment({ status: 'cancelled' })) }, ALPHA_MAIN)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Cancel appointment' }))
    // Asks first (nothing is posted yet), with an optional reason that is sent along.
    const dialog = await screen.findByRole('alertdialog')
    expect(calls.some((c) => c.path.endsWith('/cancel'))).toBe(false)
    await user.type(within(dialog).getByLabelText('Reason (optional)'), 'Patient called to cancel')
    await user.click(within(dialog).getByRole('button', { name: 'Cancel appointment' }))
    await waitFor(() => expect(calls.find((c) => c.path.endsWith('/cancel'))?.body).toEqual({ reason: 'Patient called to cancel' }))
    expect(await screen.findByText(/was cancelled\. The slot is free again\./)).toBeInTheDocument()
  })

  it('passes the status filter to the API and narrows by patient search', async () => {
    const calls = routes(['receptionist'], {}, ALPHA_MAIN)
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findAllByTestId('appointment')).toHaveLength(1)
    await user.selectOptions(screen.getByLabelText('Status'), 'no_show')
    await waitFor(() => expect(calls.some((c) => c.method === 'GET' && c.path === '/api/v1/appointments' && new URL(c.url, 'http://localhost').searchParams.get('status') === 'no_show')).toBe(true))
    await user.selectOptions(screen.getByLabelText('Status'), '')
    await user.type(screen.getByLabelText('Find patient'), 'zzz-nobody')
    await waitFor(() => expect(screen.queryAllByTestId('appointment')).toHaveLength(0))
    expect(screen.getAllByText('No matching appointments').length).toBeGreaterThan(0)
  })

  it('blocks roles outside REG_READ', async () => {
    routes(['pharmacist'])
    renderWithProviders(<App />, { path: '/appointments', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('forbidden')).toBeInTheDocument()
  })
})
