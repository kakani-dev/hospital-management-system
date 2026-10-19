import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { addDays } from '../../lib/dates'
import { at, branchesResponse, today } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const entry = (id: string, status: string) => ({ id, branchId: ALPHA_MAIN, queueDate: today(), tokenNo: 1, patientId: 'p', appointmentId: null, practitionerId: null, status, checkedInAt: at(today(), '09:00') })

function routes(roles: string[], extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'GET /api/v1/appointments': () => json({ items: [], page: 1, pageSize: 1, totalCount: 7 }),
    'GET /api/v1/queue': () => json([entry('q1', 'waiting'), entry('q2', 'waiting'), entry('q3', 'in_consultation'), entry('q4', 'done'), entry('q5', 'cancelled')]),
    'GET /api/v1/patients/stats': () => json({ total: 120, registeredToday: 3 }),
    ...extra,
  })
}

const open = () => renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })

describe('Dashboard stat cards', () => {
  it('shows real counts for the branch’s local today', async () => {
    const calls = routes(['receptionist'])
    open()
    await waitFor(() => expect(screen.getByTestId('stat-appointments')).toHaveTextContent('7'))
    await waitFor(() => expect(screen.getByTestId('stat-waiting')).toHaveTextContent('2'))
    expect(screen.getByTestId('stat-checked-in')).toHaveTextContent('4')
    await waitFor(() => expect(screen.getByTestId('stat-registered')).toHaveTextContent('3'))
    expect(screen.getByText('120 patients in total at this branch')).toBeInTheDocument()
    expect(screen.getByText('1 in consultation')).toBeInTheDocument()

    const appts = new URL(calls.find((c) => c.path === '/api/v1/appointments')!.url, 'http://x')
    expect(appts.searchParams.get('branchId')).toBe(ALPHA_MAIN)
    expect(appts.searchParams.get('from')).toBe(at(today(), '00:00'))
    expect(appts.searchParams.get('to')).toBe(at(addDays(today(), 1), '00:00'))
    expect(appts.searchParams.get('pageSize')).toBe('1')
    const queue = new URL(calls.find((c) => c.path === '/api/v1/queue')!.url, 'http://x')
    expect(queue.searchParams.get('date')).toBe(today())
    const stats = new URL(calls.find((c) => c.path === '/api/v1/patients/stats')!.url, 'http://x')
    expect(stats.searchParams.get('branchId')).toBe(ALPHA_MAIN)
    // Quick actions by capability
    expect(screen.getByRole('link', { name: 'Register patient' })).toHaveAttribute('href', '/patients/new')
    expect(screen.getByRole('link', { name: 'Check in a patient' })).toHaveAttribute('href', '/reception/check-in')
  })

  it('never invents a number: a failed count says Unavailable', async () => {
    routes(['receptionist'], { 'GET /api/v1/patients/stats': () => json({ title: 'Service Unavailable', status: 503 }, 503) })
    open()
    await waitFor(() => expect(screen.getByTestId('stat-registered')).toHaveTextContent('Unavailable'), { timeout: 5000 })
    await waitFor(() => expect(screen.getByTestId('stat-appointments')).toHaveTextContent('7'))
  })

  it('shows only the cards a role may read (lab technician: none)', async () => {
    const calls = routes(['lab_technician'])
    open()
    await screen.findByTestId('api-status')
    expect(screen.queryByTestId('dashboard-stats')).not.toBeInTheDocument()
    expect(calls.filter((c) => ['/api/v1/appointments', '/api/v1/queue', '/api/v1/patients/stats'].includes(c.path))).toEqual([])
    expect(screen.getByText('Nothing scheduled for your role.')).toBeInTheDocument()
  })
})
