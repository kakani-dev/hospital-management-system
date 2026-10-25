import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import { Route, Routes } from 'react-router'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse, today } from '../../test/schedulingFixtures'
import { formatPaise } from './money'
import { DayEndPage } from './DayEndPage'

afterEach(() => vi.unstubAllGlobals())

describe('Day end expected cash', () => {
  it('shows expected cash and the variance against the counted amount', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['billing'], ALPHA_MAIN)),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/billing-reports/day-end': () =>
        json([
          {
            sessionId: 's-open',
            counterId: 'c1',
            cashierId: 'u1',
            status: 'open',
            openingFloatPaise: 100000,
            expectedCashPaise: 150000,
            countedCashPaise: null,
            variancePaise: null,
            businessDate: today(),
          },
          {
            sessionId: 's-closed',
            counterId: 'c1',
            cashierId: 'u1',
            status: 'closed',
            openingFloatPaise: 100000,
            expectedCashPaise: 150000,
            countedCashPaise: 140000,
            variancePaise: -10000,
            businessDate: today(),
          },
        ]),
    })
    renderWithProviders(
      <Routes>
        <Route path="/billing/day-end" element={<DayEndPage />} />
      </Routes>,
      { path: `/billing/day-end?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) },
    )
    const rows = await screen.findAllByTestId('day-end-session')
    expect(rows[0]).toHaveTextContent(`Expected ${formatPaise(150000)}`)
    expect(rows[0]).not.toHaveTextContent('Variance')
    expect(rows[1]).toHaveTextContent(`Expected ${formatPaise(150000)}`)
    expect(rows[1]).toHaveTextContent(`Counted ${formatPaise(140000)}`)
    expect(rows[1]).toHaveTextContent(`Variance ${formatPaise(-10000)}`)
  })
})
