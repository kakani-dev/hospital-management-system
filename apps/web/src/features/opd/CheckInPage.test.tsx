import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, PATIENT_ID, appointment, branchesResponse, paged, patientDetail, patientRef, practitionersApi, practitionersApiWithoutBranchFilter, schedules } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const APPT = 'ap000000-0000-4000-8000-000000000001'
const entry = (overrides = {}) => ({
  id: 'q1',
  branchId: ALPHA_MAIN,
  queueDate: '2026-10-09',
  tokenNo: 7,
  patientId: PATIENT_ID,
  patient: patientRef,
  appointmentId: APPT,
  practitionerId: DR_RAO,
  status: 'waiting',
  checkedInAt: new Date().toISOString(),
  ...overrides,
})

function routes(roles: string[], extra: Parameters<typeof stubFetch>[0] = {}, branchId: string | null = ALPHA_MAIN) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, branchId)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': () => json(schedules),
    'GET /api/v1/appointments': () => json(paged([appointment()])),
    ...extra,
  })
}

describe('CheckInPage', () => {
  it('checks in a booked appointment and shows the issued token', async () => {
    const calls = routes(['receptionist'], {
      [`POST /api/v1/appointments/${APPT}/check-in`]: () => json({ queueEntryId: 'q1', tokenNo: 7, queueDate: '2026-10-09', entry: entry() }, 201),
      'POST /api/v1/accounts/from-appointment': () => json({ id: 'bill-1', accountId: 'acct-1', patientId: PATIENT_ID, branchId: ALPHA_MAIN, status: 'draft', billKind: 'final', payerType: 'self', lines: [], discounts: [], netPaise: 0, taxPaise: 0, discountPaise: 0, exactPaise: 0, roundOffPaise: 0, totalPaise: 0, duePaise: 0 }),
      [`GET /api/v1/accounts/${PATIENT_ID}/summary`]: () => json({ patientId: PATIENT_ID, advancePaise: 0, accounts: [], bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: ALPHA_MAIN, billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }] }),
      'GET /api/v1/bills/bill-1': () => json({ id: 'bill-1', billNo: null, status: 'draft', billKind: 'final', payerType: 'self', accountId: 'acct-1', patientId: PATIENT_ID, branchId: ALPHA_MAIN, lines: [{ id: 'line-1', lineNo: 1, serviceItemId: 'item-1', code: 'CONSULT', name: 'OP consultation', quantity: 1, unitPricePaise: 50000, taxRateBp: 0, netPaise: 50000, taxPaise: 0, practitionerId: null }], discounts: [], netPaise: 50000, taxPaise: 0, discountPaise: 0, exactPaise: 50000, roundOffPaise: 0, totalPaise: 50000, duePaise: 50000, cgstPaise: 0, sgstPaise: 0, igstPaise: 0, supplier: { gstin: null, stateCode: null, name: 'Alpha', address: null } }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })

    const row = await screen.findByTestId('checkin-appointment')
    await waitFor(() => expect(row).toHaveTextContent('Synthetic-Alpha, Asha'))
    await user.click(within(row).getByRole('button', { name: /^Check in Asha Synthetic-Alpha at 09:30$/ }))

    expect(await screen.findByTestId('token-number')).toHaveTextContent('7')
    expect(screen.getByTestId('token-issued')).toHaveTextContent('Checked in Asha Synthetic-Alpha.')
    expect(calls.filter((c) => c.path === `/api/v1/appointments/${APPT}/check-in`)).toHaveLength(1)
    expect(await screen.findByTestId('billing-drawer')).toBeInTheDocument()
    expect(screen.getByText('OP consultation')).toBeInTheDocument()
    expect(calls.filter((c) => c.path === '/api/v1/accounts/from-appointment')).toHaveLength(1)
    // the list refreshes after a check-in
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/appointments').length).toBeGreaterThan(1))
    // the embedded patient summary (API v2) names the row: no per-patient fetch
    expect(calls.filter((c) => c.path.startsWith('/api/v1/patients/'))).toEqual([])
  })

  it('names appointments without the summary via GET /patients/{id} (older API)', async () => {
    const calls = routes(['receptionist'], {
      'GET /api/v1/appointments': () => json(paged([appointment({ patient: undefined })])),
      [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(patientDetail),
    })
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getByTestId('checkin-appointment')).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(calls.filter((c) => c.path === `/api/v1/patients/${PATIENT_ID}`)).toHaveLength(1)
  })

  it('walk-in doctor list falls back to schedules at the branch when ?branchId= is rejected (400)', async () => {
    routes(['receptionist'], {
      'GET /api/v1/practitioners': practitionersApiWithoutBranchFilter,
      'GET /api/v1/schedules': (url) => json(schedules.filter((s) => s.branchId === url.searchParams.get('branchId'))),
    })
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    const form = await screen.findByRole('form', { name: 'Walk-in check-in' })
    await waitFor(() => expect(within(within(form).getByLabelText('Doctor (optional)')).getAllByRole('option').map((o) => o.textContent)).toEqual([expect.any(String), expect.stringContaining('Dr. Rao')]))
  })

  it.each([
    ['already_checked_in', 'already waiting or in consultation'],
    ['invalid_state', 'Only appointments for today'],
    ['invalid_transition', 'no longer booked'],
  ])('maps 409 %s to a clear message', async (code, message) => {
    routes(['nurse'], { [`POST /api/v1/appointments/${APPT}/check-in`]: () => json({ title: 'Conflict', status: 409, code }, 409) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: /^Check in/ }))
    expect(await screen.findByRole('alert')).toHaveTextContent(message)
    expect(screen.queryByTestId('token-issued')).not.toBeInTheDocument()
  })

  it('issues a walk-in token for a searched patient with an optional doctor', async () => {
    const calls = routes(['receptionist'], {
      'POST /api/v1/patients/search': () => json({ items: [patientDetail], page: 1, pageSize: 25, totalCount: 1 }),
      'POST /api/v1/queue/walk-in': () => json({ queueEntryId: 'q2', tokenNo: 8, queueDate: '2026-10-09', entry: entry({ id: 'q2', tokenNo: 8, appointmentId: null }) }, 201),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    const form = await screen.findByRole('form', { name: 'Walk-in check-in' })
    await user.click(within(form).getByRole('button', { name: 'Issue walk-in token' }))
    expect(within(form).getByRole('alert')).toHaveTextContent('Choose a patient first.')

    await user.type(within(form).getByLabelText('Find walk-in patient'), 'ALP-0001')
    await user.click(await within(form).findByRole('option', { name: /Synthetic-Alpha, Asha/ }))
    // GET /practitioners?branchId=: only doctors working at Alpha Main
    await waitFor(() => expect(within(within(form).getByLabelText('Doctor (optional)')).getAllByRole('option').map((o) => o.textContent)).toEqual([expect.any(String), expect.stringContaining('Dr. Rao')]))
    await user.selectOptions(within(form).getByLabelText('Doctor (optional)'), DR_RAO)
    await user.click(within(form).getByRole('button', { name: 'Issue walk-in token' }))

    expect(await screen.findByTestId('token-number')).toHaveTextContent('8')
    expect(calls.find((c) => c.path === '/api/v1/queue/walk-in')!.body).toEqual({ branchId: ALPHA_MAIN, patientId: PATIENT_ID, practitionerId: DR_RAO })
  })

  it('hides check-in actions where the role is not held at the selected branch; doctors cannot open the page', async () => {
    routes(['receptionist'], {}, ALPHA_EAST)
    const { unmount } = renderWithProviders(<App />, { path: `/reception/check-in?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })
    // ALPHA_MAIN is not accessible: the picker falls back to the receptionist's own branch
    expect(await screen.findByLabelText('Showing branch')).toHaveValue(ALPHA_EAST)
    unmount()

    routes(['doctor'])
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('forbidden')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Check-in' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'OPD queue' })).toBeInTheDocument()
  })
})
