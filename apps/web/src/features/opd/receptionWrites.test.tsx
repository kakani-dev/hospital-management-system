import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, PATIENT_ID, appointment, at, branchesResponse, paged, patientRef, practitionersApi, schedules, today } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

/** A response the test releases by hand (for "while the write is in flight" assertions). */
function deferred() {
  let release!: (r: Response) => void
  const promise = new Promise<Response>((resolve) => (release = resolve))
  return { promise, release }
}

const unavailable = () => json({ title: 'Service Unavailable', status: 503, code: 'service_unavailable' }, 503, { 'Retry-After': '5' })

const queueEntry = (id: string, tokenNo: number, status: string) => ({
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
})

function base(roles: string[], extra: Parameters<typeof stubFetch>[0]) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': () => json(schedules),
    ...extra,
  })
}

describe('queue board: optimistic moves', () => {
  it('moves the token at once, marks only that card as saving, then settles', async () => {
    const patch = deferred()
    let server = [queueEntry('q1', 1, 'waiting'), queueEntry('q2', 2, 'waiting')]
    base(['doctor'], {
      'GET /api/v1/queue': () => json(server),
      'PATCH /api/v1/queue/q1': () => patch.promise,
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })

    await user.click(await screen.findByRole('button', { name: 'Call in token 1' }))
    // Optimistic: already in consultation before the server answered
    const consult = screen.getByTestId('queue-in_consultation')
    await waitFor(() => expect(within(consult).getByTestId('queue-entry')).toHaveAttribute('data-token', '1'))
    expect(within(consult).getByTestId('queue-entry-saving')).toHaveTextContent('Saving…')
    expect(within(consult).getByTestId('queue-entry')).toHaveAttribute('aria-busy', 'true')
    // Other tokens stay usable
    expect(screen.getByRole('button', { name: 'Call in token 2' })).toBeEnabled()

    server = [queueEntry('q1', 1, 'in_consultation'), queueEntry('q2', 2, 'waiting')]
    patch.release(json(server[0]))
    await waitFor(() => expect(screen.queryByTestId('queue-entry-saving')).not.toBeInTheDocument())
    expect(within(screen.getByTestId('queue-in_consultation')).getByTestId('queue-entry')).toHaveAttribute('data-token', '1')
  })

  it('rolls the card back when the server rejects the move', async () => {
    const calls = base(['doctor'], {
      'GET /api/v1/queue': () => json([queueEntry('q1', 1, 'waiting')]),
      'PATCH /api/v1/queue/q1': () => json({ title: 'Server error', status: 500 }, 500),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Call in token 1' }))
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    await waitFor(() => expect(within(screen.getByTestId('queue-waiting')).getByTestId('queue-entry')).toHaveAttribute('data-token', '1'))
    expect(within(screen.getByTestId('queue-in_consultation')).queryByTestId('queue-entry')).not.toBeInTheDocument()
    expect(calls.filter((c) => c.method === 'PATCH')).toHaveLength(1)
  })

  it('a 503 is not auto-retried: rollback + Retry button, which re-sends the move', async () => {
    let attempts = 0
    let status = 'waiting'
    const calls = base(['doctor'], {
      'GET /api/v1/queue': () => json([queueEntry('q1', 1, status)]),
      'PATCH /api/v1/queue/q1': () => {
        attempts += 1
        if (attempts === 1) return unavailable()
        status = 'in_consultation'
        return json(queueEntry('q1', 1, status))
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Call in token 1' }))
    const alert = await screen.findByTestId('retry-alert')
    expect(alert).toHaveTextContent(/waking up or busy/i)
    expect(calls.filter((c) => c.method === 'PATCH')).toHaveLength(1)
    await waitFor(() => expect(within(screen.getByTestId('queue-waiting')).getByTestId('queue-entry')).toHaveAttribute('data-token', '1'))

    await user.click(within(alert).getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(within(screen.getByTestId('queue-in_consultation')).getByTestId('queue-entry')).toHaveAttribute('data-token', '1'))
    expect(calls.filter((c) => c.method === 'PATCH')).toHaveLength(2)
    expect(screen.queryByTestId('retry-alert')).not.toBeInTheDocument()
  })
})

describe('check-in: per-row pending and Retry', () => {
  const A1 = 'ap000000-0000-4000-8000-000000000001'
  const A2 = 'ap000000-0000-4000-8000-000000000002'
  const result = (tokenNo: number) => ({ queueEntryId: `q${tokenNo}`, tokenNo, queueDate: today(), entry: queueEntry(`q${tokenNo}`, tokenNo, 'waiting') })

  it('only the row being checked in is busy', async () => {
    const post = deferred()
    base(['receptionist'], {
      'GET /api/v1/appointments': () =>
        json(paged([appointment({ id: A1, startsAt: at(today(), '09:30'), endsAt: at(today(), '09:45') }), appointment({ id: A2, startsAt: at(today(), '10:00'), endsAt: at(today(), '10:15') })])),
      [`POST /api/v1/appointments/${A1}/check-in`]: () => post.promise,
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    await waitFor(() => expect(screen.getAllByTestId('checkin-appointment')).toHaveLength(2))
    await user.click(screen.getByRole('button', { name: /^Check in Asha Synthetic-Alpha at 09:30$/ }))

    const [first, second] = screen.getAllByTestId('checkin-appointment')
    await waitFor(() => expect(first).toHaveAttribute('aria-busy', 'true'))
    expect(within(first!).getByRole('button', { name: /09:30/ })).toHaveTextContent('Checking in…')
    expect(within(first!).getByRole('button', { name: /09:30/ })).toBeDisabled()
    expect(second).toHaveAttribute('aria-busy', 'false')
    expect(within(second!).getByRole('button', { name: /10:00/ })).toBeEnabled()

    post.release(json(result(7), 201))
    expect(await screen.findByTestId('token-number')).toHaveTextContent('7')
    await waitFor(() => expect(screen.getByTestId('token-issued')).toHaveFocus())
  })

  it('a 503 on check-in shows Retry (never auto-retried); Retry issues the token', async () => {
    let attempts = 0
    const calls = base(['receptionist'], {
      'GET /api/v1/appointments': () => json(paged([appointment({ id: A1 })])),
      [`POST /api/v1/appointments/${A1}/check-in`]: () => (++attempts === 1 ? unavailable() : json(result(9), 201)),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/reception/check-in', auth: fakeAuthClient({ session: fakeSession() }) })
    const row = await screen.findByTestId('checkin-appointment')
    await waitFor(() => expect(row).toHaveTextContent('Synthetic-Alpha, Asha'))
    await user.click(within(row).getByRole('button', { name: /^Check in/ }))

    const alert = await screen.findByTestId('retry-alert')
    expect(alert).toHaveTextContent(/Nothing was saved/)
    expect(calls.filter((c) => c.method === 'POST')).toHaveLength(1)
    await user.click(within(alert).getByRole('button', { name: 'Retry' }))
    expect(await screen.findByTestId('token-number')).toHaveTextContent('9')
    expect(calls.filter((c) => c.method === 'POST' && c.path.endsWith('/check-in'))).toHaveLength(2)
    expect(screen.queryByTestId('retry-alert')).not.toBeInTheDocument()
  })
})
