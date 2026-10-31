import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { PATIENT_ID, branchesResponse, patientDetail } from '../../test/schedulingFixtures'

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); localStorage.clear() })

const createdOn = new Date(Date.now() - 20 * 60_000).toISOString()
const draft = (duePaise: number, status = 'draft') => ({
  id: 'b1', billNo: null, status, billKind: 'final', patientId: PATIENT_ID, accountId: 'a1', totalPaise: 50000, discountPaise: 0, duePaise,
  lines: [{ id: 'l1', name: 'Consultation (Zz-QA)', quantity: 1, netPaise: 50000, taxPaise: 0 }], payments: [], rowVersion: 1, createdOn,
})

function routes(roles: string[], state: { due: number }, branch: string | null = ALPHA_MAIN) {
  const me = meWithRoles(roles, branch)
  return stubFetch({
    'GET /api/v1/me': () => json(me),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/bills': () => json(state.due > 0 ? [{ ...draft(state.due), patientName: 'Zz-QA Counter Patient' }] : []),
    'GET /api/v1/bills/b1': () => json(draft(state.due, state.due > 0 ? 'draft' : 'final')),
    'POST /api/v1/bills/b1/finalize': () => json(draft(0, 'final')),
    'GET /api/v1/queue': () => json([]),
    'GET /api/v1/billing-reports/day-end/accounts': () => json({ accounts: [{ mode: 'cash', netPaise: 120000, count: 3 }] }),
    [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(patientDetail),
    'POST /api/v1/counter-sessions/ensure': () => json({ id: 's1', status: 'open' }),
    'POST /api/v1/payments': () => { state.due = 0; return json({ id: 'r9', receiptNo: 'RCPT-9', amountPaise: 50000, tenders: [] }) },
  })
}

describe('OpCounterPage', () => {
  it('billing role is collect-only: no register and no doctor tokens, but can collect a waiting bill in cash with change', async () => {
    const calls = routes(['billing'], { due: 50000 })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/billing/counter', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByTestId('opc-waiting-b1'))
    expect(await screen.findByTestId('opc-due')).toHaveTextContent('₹500.00')
    expect(screen.queryByTestId('opc-register')).not.toBeInTheDocument()
    expect(screen.queryByTestId(/^opc-doctor-/)).not.toBeInTheDocument()
    await user.type(screen.getByTestId('opc-received'), '2000')
    expect(screen.getByTestId('opc-change')).toHaveTextContent('₹1,500.00')
    await user.click(screen.getByTestId('opc-collect'))
    await waitFor(() => expect(calls.some((c) => c.method === 'POST' && c.path === '/api/v1/payments')).toBe(true))
    const pay = calls.find((c) => c.path === '/api/v1/payments')!
    expect(pay.headers.get('Idempotency-Key')).toBeTruthy()
    expect(pay.body).toMatchObject({ tenders: [{ mode: 'cash', amountPaise: 50000 }], allocations: [{ billId: 'b1', amountPaise: 50000 }] })
    expect(await screen.findByTestId('opc-notice')).toHaveTextContent('give back ₹1,500.00')
    expect(await screen.findByTestId('opc-print-frame')).toHaveAttribute('src', expect.stringContaining('/billing/receipts/r9'))
    await waitFor(() => expect(screen.getByTestId('opc-search')).toHaveFocus())
  })

  it('shows today\u2019s collection by mode and reopens the remembered branch', async () => {
    const calls = routes(['receptionist'], { due: 0 }, null)
    localStorage.setItem('hms.opCounter.branch.0a000000-0000-4000-8000-000000000001', ALPHA_EAST)
    renderWithProviders(<App />, { path: '/billing/counter', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('opc-total-cash')).toHaveTextContent('₹1,200.00')
    expect(screen.getByTestId('opc-search')).toBeInTheDocument()
    await waitFor(() => expect(calls.some((c) => c.path === '/api/v1/billing-reports/day-end/accounts' && c.url.includes(ALPHA_EAST))).toBe(true))
  })
})
