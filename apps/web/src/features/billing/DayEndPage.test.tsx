import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Route, Routes } from 'react-router'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse, today } from '../../test/schedulingFixtures'
import type { DayCloseSummary } from '../../lib/api/types'
import { formatPaise } from './money'
import { DayEndPage } from './DayEndPage'

afterEach(() => vi.unstubAllGlobals())

function summary(over: Partial<DayCloseSummary> = {}): DayCloseSummary {
  return {
    branchId: ALPHA_MAIN,
    date: today(),
    cash: { expectedPaise: 160000, countedPaise: 140000, variancePaise: -10000 },
    sessions: [
      {
        sessionId: 's-open', counterId: 'c1', counterName: 'Zz-QA Counter 1', cashierId: 'u1', mine: true, status: 'open',
        openedAt: new Date().toISOString(), closedAt: null, openingFloatPaise: 0, expectedCashPaise: 10000,
        countedCashPaise: null, variancePaise: null, varianceReason: null, handover: null,
      },
      {
        sessionId: 's-closed', counterId: 'c2', counterName: 'Zz-QA Counter 2', cashierId: 'u2', mine: false, status: 'closed',
        openedAt: new Date().toISOString(), closedAt: new Date().toISOString(), openingFloatPaise: 100000, expectedCashPaise: 150000,
        countedCashPaise: 140000, variancePaise: -10000, varianceReason: 'Change given short',
        handover: { id: 'h1', amountPaise: 50000, note: null, receivedBy: null, receivedAt: null },
      },
    ],
    methods: [
      { mode: 'card', paymentAccountId: null, label: 'Unassigned', receivedPaise: 30000, refundedPaise: 0, expectedPaise: 30000, count: 1,
        settledPaise: null, variancePaise: null, reason: null, recordedBy: null, recordedAt: null, stale: false },
      { mode: 'upi', paymentAccountId: 'pa-1', label: 'Zz-QA UPI', receivedPaise: 25000, refundedPaise: 5000, expectedPaise: 20000, count: 3,
        settledPaise: null, variancePaise: null, reason: null, recordedBy: null, recordedAt: null, stale: false },
    ],
    otherVariancePaise: 0,
    expectedTotalPaise: 210000,
    advances: { count: 2, amountPaise: 70000 },
    refunds: { count: 1, amountPaise: 5000 },
    credit: { count: 0, amountPaise: 0 },
    flowByMode: { upi: { advancePaise: 20000, refundPaise: 5000 } },
    signoff: null,
    blockers: ['open_sessions', 'unsettled_methods'],
    varianceReasons: ['Counting error', 'Gateway fee deducted'],
    methodLabels: { cash: 'Cash', card: 'Card (EDC)', upi: 'UPI', bank: 'Bank / cheque' },
    ...over,
  }
}

function renderPage(roles: string[], routes: Parameters<typeof stubFetch>[0] = {}, data = summary()) {
  const calls = stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/billing-reports/day-close': () => json(data),
    ...routes,
  })
  renderWithProviders(
    <Routes>
      <Route path="/billing/day-end" element={<DayEndPage />} />
    </Routes>,
    { path: `/billing/day-end?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) },
  )
  return calls
}

describe('Day end close (all methods)', () => {
  it('shows every drawer, method, advances and refunds on one screen', async () => {
    renderPage(['billing'])
    const rows = await screen.findAllByTestId('day-end-session')
    expect(rows[0]).toHaveTextContent(`Expected ${formatPaise(10000)}`)
    expect(rows[1]).toHaveTextContent(`Variance ${formatPaise(-10000)}`)
    expect(within(rows[1]!).getByTestId('session-reason')).toHaveTextContent('Change given short')
    const methods = screen.getAllByTestId('dc-method')
    expect(methods[0]).toHaveTextContent('Card (EDC)')
    expect(methods[1]).toHaveTextContent('UPI · Zz-QA UPI')
    expect(methods[1]).toHaveTextContent(`refunds ${formatPaise(5000)}`)
    expect(screen.getByTestId('dc-flow')).toHaveTextContent(`Advances 2 · ${formatPaise(70000)}`)
    expect(screen.getByTestId('dc-expected-total')).toHaveTextContent(formatPaise(210000))
    expect(screen.queryByTestId('dc-signoff')).not.toBeInTheDocument()
  })

  it('needs a reason before a short drawer closes, then sends count, reason and handover', async () => {
    const calls = renderPage(['billing'], {
      'POST /api/v1/billing-reports/day-close/sessions/s-open/close': () => json({ sessionId: 's-open', variancePaise: -500 }),
    })
    const user = userEvent.setup()
    await user.type(await screen.findByTestId('close-counted'), '95')
    await user.type(screen.getByTestId('close-handover'), '50')
    expect(screen.getByTestId('close-variance')).toHaveTextContent(formatPaise(-500))
    expect(screen.getByTestId('close-drawer')).toBeDisabled()
    await user.type(screen.getByTestId('close-reason'), 'Counting error')
    await user.click(screen.getByTestId('close-drawer'))
    await waitFor(() => expect(calls.some((c) => c.method === 'POST' && c.path.endsWith('/s-open/close'))).toBe(true))
    expect(calls.find((c) => c.path.endsWith('/s-open/close'))?.body).toEqual({ countedCashPaise: 9500, handoverPaise: 5000, reason: 'Counting error' })
  })

  it('one tap fills the expected count and no reason is asked', async () => {
    renderPage(['billing'])
    const user = userEvent.setup()
    await user.click(await screen.findByTestId('close-counted-match'))
    expect(screen.getByTestId('close-counted')).toHaveValue('100.00')
    expect(screen.queryByTestId('close-reason')).not.toBeInTheDocument()
    expect(screen.getByTestId('close-drawer')).toBeEnabled()
  })

  it('the incoming cashier receives a handover in one tap', async () => {
    const calls = renderPage(['billing'], {
      'POST /api/v1/billing-reports/day-close/handovers/h1/receive': () => json({ handoverId: 'h1', toSessionId: 's-open', amountPaise: 50000 }),
    })
    await userEvent.setup().click(await screen.findByTestId('receive-handover'))
    await waitFor(() => expect(calls.some((c) => c.method === 'POST' && c.path.endsWith('/h1/receive'))).toBe(true))
  })

  it('settlements default to expected and a difference needs a reason', async () => {
    const calls = renderPage(['billing'], {
      'PUT /api/v1/billing-reports/day-close/settlements': () => json(summary({ blockers: ['open_sessions'] })),
    })
    const user = userEvent.setup()
    const inputs = await screen.findAllByTestId('dc-settled')
    expect(inputs[0]).toHaveValue('300.00')
    await user.clear(inputs[1]!)
    await user.type(inputs[1]!, '190')
    expect(screen.getByTestId('dc-save-settlements')).toBeDisabled()
    await user.type(screen.getByTestId('dc-reason'), 'Gateway fee deducted')
    await user.click(screen.getByTestId('dc-save-settlements'))
    await waitFor(() => expect(calls.some((c) => c.method === 'PUT')).toBe(true))
    expect(calls.find((c) => c.method === 'PUT')?.body).toEqual({
      items: [
        { mode: 'card', paymentAccountId: null, settledPaise: 30000 },
        { mode: 'upi', paymentAccountId: 'pa-1', settledPaise: 19000, reason: 'Gateway fee deducted' },
      ],
    })
  })

  it('a supervisor sees what blocks sign-off and cannot sign until it is clear', async () => {
    renderPage(['tenant_admin'])
    expect(await screen.findByTestId('dc-blockers')).toHaveTextContent('A cash drawer is still open.')
    expect(screen.getByTestId('dc-signoff-submit')).toBeDisabled()
  })

  it('a supervisor signs off a clear day with a note', async () => {
    const signed = summary({
      blockers: [],
      signoff: { id: 'g1', signedBy: 'u9', signedAt: new Date().toISOString(), note: 'Zz-QA ok', cashVariancePaise: -10000, otherVariancePaise: 0, changedSince: false },
    })
    const calls = renderPage(['tenant_admin'], { 'POST /api/v1/billing-reports/day-close/signoff': () => json(signed) }, summary({ blockers: [] }))
    const user = userEvent.setup()
    await user.type(await screen.findByTestId('dc-signoff-note'), 'Zz-QA ok')
    await user.click(screen.getByTestId('dc-signoff-submit'))
    expect(await screen.findByTestId('day-close-signed')).toHaveTextContent('Zz-QA ok')
    expect(calls.find((c) => c.path.endsWith('/signoff'))?.body).toEqual({ note: 'Zz-QA ok' })
    expect(screen.queryByTestId('close-drawer')).not.toBeInTheDocument()
  })
})
