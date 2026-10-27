import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Route, Routes } from 'react-router'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, PATIENT_ID, branchesResponse, patientDetail, patientRef, practitionersApi, today } from '../../test/schedulingFixtures'
import { QueueBoardPage } from './QueueBoardPage'

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

const entry = (id: string, tokenNo: number, status: string, overrides = {}) => ({
  id,
  branchId: ALPHA_MAIN,
  queueDate: today(),
  tokenNo,
  patientId: PATIENT_ID,
  patient: patientRef,
  appointmentId: null,
  practitionerId: DR_RAO,
  status,
  checkedInAt: new Date().toISOString(),
  ...overrides,
})

function routes(roles: string[], queue: () => unknown[], extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/queue': () => json(queue()),
    ...extra,
  })
}

describe('QueueBoardPage', () => {
  it('groups tokens by status for the branch-local day and requests ?branchId&date', async () => {
    const calls = routes(['receptionist'], () => [entry('q3', 3, 'done'), entry('q1', 1, 'waiting'), entry('q2', 2, 'in_consultation'), entry('q4', 4, 'cancelled')])
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })

    const waiting = await screen.findByTestId('queue-waiting')
    await waitFor(() => expect(within(waiting).getByTestId('queue-entry')).toHaveAttribute('data-token', '1'))
    expect(within(screen.getByTestId('queue-in_consultation')).getByTestId('queue-entry')).toHaveAttribute('data-token', '2')
    expect(within(screen.getByTestId('queue-done')).getByTestId('queue-entry')).toHaveAttribute('data-token', '3')
    expect(screen.getByTestId('queue-cancelled-count')).toHaveTextContent('1 token removed')
    await waitFor(() => expect(within(waiting).getByTestId('queue-entry')).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(within(waiting).getByTestId('queue-entry')).toHaveTextContent('Dr. Rao (synthetic) · walk-in')
    // RBAC: front desk (queue.manage) may move tokens; billing no longer sees the queue at all
    expect(screen.getAllByRole('button', { name: /token 1/ }).length).toBeGreaterThan(0)
    const url = new URL(calls.find((c) => c.path === '/api/v1/queue')!.url, 'http://x')
    expect(Object.fromEntries(url.searchParams)).toEqual({ branchId: ALPHA_MAIN, date: today() })
    // API v2 patient summary: no per-patient fetches
    expect(calls.filter((c) => c.path.startsWith('/api/v1/patients/'))).toEqual([])
  })

  it('patient: null (soft-deleted / not readable) shows "Patient unavailable" without fetching', async () => {
    const calls = routes(['nurse'], () => [entry('q1', 1, 'waiting', { patient: null })])
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getByTestId('queue-entry')).toHaveTextContent('Patient unavailable'))
    expect(calls.filter((c) => c.path.startsWith('/api/v1/patients/'))).toEqual([])
  })

  it('looks a patient up only when the entry lacks the summary (older API)', async () => {
    const calls = routes(['nurse'], () => [entry('q1', 1, 'waiting', { patient: undefined })], {
      [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(patientDetail),
    })
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getByTestId('queue-entry')).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(calls.filter((c) => c.path === `/api/v1/patients/${PATIENT_ID}`)).toHaveLength(1)
  })

  it('a doctor calls in and finishes tokens but cannot remove them', async () => {
    let status = 'waiting'
    const calls = routes(['doctor'], () => [entry('q1', 1, status)], {
      'PATCH /api/v1/queue/q1': (_u, init) => {
        status = JSON.parse(String(init.body)).status
        return json(entry('q1', 1, status))
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })

    expect(screen.queryByRole('button', { name: 'Remove token 1' })).not.toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'Call in token 1' }))
    await waitFor(() => expect(within(screen.getByTestId('queue-in_consultation')).queryByTestId('queue-entry')).toBeInTheDocument())
    await user.click(screen.getByRole('button', { name: 'Mark done token 1' }))
    await waitFor(() => expect(within(screen.getByTestId('queue-done')).queryByTestId('queue-entry')).toBeInTheDocument())
    expect(calls.filter((c) => c.method === 'PATCH').map((c) => c.body)).toEqual([{ status: 'in_consultation' }, { status: 'done' }])
  })

  it('front desk can remove a waiting token; a 409 invalid_transition explains and refreshes', async () => {
    const calls = routes(['receptionist'], () => [entry('q1', 1, 'waiting')], {
      'PATCH /api/v1/queue/q1': () => json({ title: 'Conflict', status: 409, code: 'invalid_transition' }, 409),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Remove token 1' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Token 1 was already updated elsewhere')
    expect(calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'cancelled' })
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/queue').length).toBeGreaterThan(1))
  })

  it('polls the queue (live-ish refresh)', async () => {
    let tokens = [entry('q1', 1, 'waiting')]
    const calls = routes(['nurse'], () => tokens)
    renderWithProviders(
      <Routes>
        <Route path="/queue" element={<QueueBoardPage refreshMs={200} />} />
      </Routes>,
      { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) },
    )
    await waitFor(() => expect(screen.getAllByTestId('queue-entry')).toHaveLength(1))
    expect(screen.getByTestId('queue-updated')).toHaveTextContent('refreshes every 0 s')
    await act(async () => {
      tokens = [...tokens, entry('q2', 2, 'waiting')]
    })
    await waitFor(() => expect(screen.getAllByTestId('queue-entry')).toHaveLength(2), { timeout: 2000 })
    expect(calls.filter((c) => c.path === '/api/v1/queue').length).toBeGreaterThan(1)
  })

  it('front desk cannot close today early and sees the automatic close note (#142)', async () => {
    const calls = routes(['receptionist'], () => [entry('q1', 1, 'waiting')])
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('queue-auto-close-hint')).toHaveTextContent('closes automatically after midnight')
    expect(screen.queryByTestId('queue-close-day-button')).not.toBeInTheDocument()
    expect(calls.find((c) => c.path === '/api/v1/queue/close-day')).toBeUndefined()
  })

  it('an admin closes today early only with a reason, and waiting tokens move to closed', async () => {
    let closed = false
    const calls = routes(
      ['tenant_admin'],
      () => (closed ? [entry('q1', 1, 'expired'), entry('q2', 2, 'in_consultation')] : [entry('q1', 1, 'waiting'), entry('q2', 2, 'in_consultation')]),
      {
        'POST /api/v1/queue/close-day': () => {
          closed = true
          return json({ branchId: ALPHA_MAIN, queueDate: today(), expiredCount: 1 })
        },
      },
    )
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByTestId('queue-close-day-button'))
    expect(screen.queryByTestId('queue-auto-close-hint')).not.toBeInTheDocument()
    // no reason: blocked in the dialog, nothing sent
    await user.click(await screen.findByRole('button', { name: 'Expire waiting tokens' }))
    expect(await screen.findByTestId('queue-close-reason-error')).toHaveTextContent('3 to 500 characters')
    expect(calls.find((c) => c.path === '/api/v1/queue/close-day')).toBeUndefined()

    await user.type(screen.getByTestId('queue-close-reason'), '  Zz-QA emergency closure ')
    await user.click(screen.getByRole('button', { name: 'Expire waiting tokens' }))
    expect(await screen.findByText(/1 waiting token expired/)).toBeInTheDocument()
    const closedColumn = await screen.findByTestId('queue-expired')
    expect(within(closedColumn).getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
    expect(within(screen.getByTestId('queue-in_consultation')).getByTestId('queue-entry')).toHaveAttribute('data-token', '2')
    expect(calls.find((c) => c.path === '/api/v1/queue/close-day')?.body).toEqual({ branchId: ALPHA_MAIN, date: today(), reason: 'Zz-QA emergency closure' })
  })

  it('shows the server message when the early close is refused', async () => {
    routes(['tenant_admin'], () => [entry('q1', 1, 'waiting')], {
      'POST /api/v1/queue/close-day': () =>
        json({ status: 400, title: 'Validation failed', detail: 'A queue day cannot be closed before it ends in the branch time zone.' }, 400),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByTestId('queue-close-day-button'))
    await user.type(screen.getByTestId('queue-close-reason'), 'Zz-QA power cut')
    await user.click(screen.getByRole('button', { name: 'Expire waiting tokens' }))
    expect(await screen.findByText(/cannot be closed before it ends in the branch time zone/)).toBeInTheDocument()
  })
})
