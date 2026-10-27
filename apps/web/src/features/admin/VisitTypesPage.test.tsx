import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { VisitTypesPage } from './VisitTypesPage'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const consult = {
  id: 'f1111111-0000-4000-8000-000000000001', code: 'new_consult', name: 'New consultation',
  defaultFeePaise: 50000, durationMinutes: 15, followUpValidDays: 7, followUpFeePaise: 0, followUpFreeLimit: 1,
  sortOrder: 1, isActive: true, effectiveFeePaise: 50000, effectiveDurationMinutes: 15,
  effectiveFollowUpValidDays: 7, effectiveFollowUpFeePaise: 0,
}

function setup() {
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/visit-types': () => json([consult]),
    [`PATCH /api/v1/visit-types/${consult.id}`]: (_u, init) => json({ ...consult, ...JSON.parse(String(init.body)) }),
  })
}

describe('VisitTypesPage free follow-ups', () => {
  it('shows the follow-up fee and free count and saves a new count and a reduced fee', async () => {
    const calls = setup()
    renderWithProviders(<VisitTypesPage />, { auth: fakeAuthClient({ session: fakeSession() }) })
    const fee = await screen.findByTestId('admin-visittypes-followup-fee')
    const limit = screen.getByTestId('admin-visittypes-free-limit')
    expect(fee).toHaveValue('0')
    expect(limit).toHaveValue('1')
    await userEvent.clear(fee)
    await userEvent.type(fee, '100')
    await userEvent.clear(limit)
    await userEvent.type(limit, '2')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(calls.some((c) => c.method === 'PATCH')).toBe(true))
    const body = calls.find((c) => c.method === 'PATCH')!.body as Record<string, unknown>
    expect(body.followUpFeePaise).toBe(10000)
    expect(body.followUpFreeLimit).toBe(2)
  })

  it('clears the limit when blank and rejects an out-of-range count', async () => {
    const calls = setup()
    renderWithProviders(<VisitTypesPage />, { auth: fakeAuthClient({ session: fakeSession() }) })
    const limit = await screen.findByTestId('admin-visittypes-free-limit')
    await userEvent.clear(limit)
    await userEvent.type(limit, '51')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(await screen.findByText('Free follow-ups is 0 to 50, or blank for no limit.')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'PATCH')).toBe(false)
    await userEvent.clear(limit)
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(calls.some((c) => c.method === 'PATCH')).toBe(true))
    expect((calls.find((c) => c.method === 'PATCH')!.body as Record<string, unknown>).clearFollowUpFreeLimit).toBe(true)
  })
})
