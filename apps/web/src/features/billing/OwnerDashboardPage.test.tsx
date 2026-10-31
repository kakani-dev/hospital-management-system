import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { addDays } from '../../lib/dates'
import { branchesResponse, today } from '../../test/schedulingFixtures'
import { rangeFor } from './OwnerDashboardPage'

let collected = 800_000
afterEach(() => { vi.unstubAllGlobals(); collected = 800_000 })

const day = (date: string) => ({ date, opdVisits: 12, newPatients: 4, noShows: 2, billedPaise: 1_000_000, discountPaise: 20_000, creditNotePaise: 0, collectedPaise: collected, refundPaise: 10_000, pharmacySales: 9, pharmacySalesPaise: 45_000 })
const report = (from: string, to: string) => {
  const days = [] as ReturnType<typeof day>[]
  for (let d = from; d <= to; d = addDays(d, 1)) days.push(day(d))
  const sum = (k: keyof ReturnType<typeof day>) => days.reduce((a, x) => a + (x[k] as number), 0)
  return { from, to, branchId: null, byMode: { upi: 500_000 * days.length, cash: 300_000 * days.length, card: 0 },
    totals: { opdVisits: sum('opdVisits'), newPatients: sum('newPatients'), noShows: sum('noShows'), billedPaise: sum('billedPaise'), discountPaise: sum('discountPaise'), creditNotePaise: 0, collectedPaise: sum('collectedPaise'), refundPaise: sum('refundPaise'), pharmacySales: sum('pharmacySales'), pharmacySalesPaise: sum('pharmacySalesPaise') }, days }
}

function routes(roles: string[]) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'GET /api/v1/billing-reports/owner-kpis': (u: URL) => {
      return json(report(u.searchParams.get('from')!, u.searchParams.get('to')!))
    },
    'GET /api/v1/inventory/stock/alerts': () => json({ branchId: ALPHA_MAIN, nearExpiryDays: 90, counts: { expired: 1, nearExpiry: 3, lowStock: 2 }, lowStock: [], expiry: [] }),
  })
}

const open = () => renderWithProviders(<App />, { path: '/billing/owner', auth: fakeAuthClient({ session: fakeSession() }) })

describe('Owner dashboard', () => {
  it('never shows negative dues when collections and advances exceed billing', async () => {
    collected = 1_108_299 // ₹11,082.99 in, ₹10,000 billed, ₹100 refunded → ₹982.99 ahead
    routes(['tenant_admin'])
    open()
    await waitFor(() => expect(screen.getByTestId('kpi-outstanding')).toHaveTextContent('₹0'))
    expect(screen.getByTestId('kpi-outstanding')).not.toHaveTextContent('-')
    expect(screen.getByText(/982\.99 collected ahead of billing/)).toBeInTheDocument()
  })

  it('computes preset ranges from a relative today', () => {
    const t = today()
    expect(rangeFor('today', t)).toEqual({ from: t, to: t })
    expect(rangeFor('7d', t)).toEqual({ from: addDays(t, -6), to: t })
    expect(rangeFor('yesterday', t)).toEqual({ from: addDays(t, -1), to: addDays(t, -1) })
    expect(rangeFor('month', t).from.endsWith('-01')).toBe(true)
  })

  it('shows today’s KPIs, collections by method and stock alerts on one screen', async () => {
    const calls = routes(['tenant_admin'])
    open()
    await waitFor(() => expect(screen.getByTestId('kpi-opd-visits')).toHaveTextContent('12'))
    expect(screen.getByTestId('kpi-new-patients')).toHaveTextContent('4')
    expect(screen.getByTestId('kpi-no-shows')).toHaveTextContent('2')
    expect(screen.getByTestId('kpi-billed')).toHaveTextContent('10,000')
    expect(screen.getByTestId('kpi-collected')).toHaveTextContent('8,000')
    expect(screen.getByTestId('kpi-outstanding')).toHaveTextContent('2,100')
    expect(screen.getByTestId('kpi-mode-upi')).toHaveTextContent('5,000')
    expect(screen.queryByTestId('kpi-mode-card')).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('kpi-stock-alerts')).toHaveTextContent('Expired on shelf1'))
    const q = new URL(calls.find((c) => c.path === '/api/v1/billing-reports/owner-kpis')!.url, 'http://x')
    expect(q.searchParams.get('from')).toBe(today())
    expect(q.searchParams.get('to')).toBe(today())
    expect(screen.queryAllByTestId('kpi-day')).toHaveLength(0)

    await userEvent.click(screen.getByTestId('owner-range-7d'))
    await waitFor(() => expect(screen.getAllByTestId('kpi-day')).toHaveLength(7))
    expect(screen.getByTestId('kpi-opd-visits')).toHaveTextContent('84')
    expect(screen.getByTestId('owner-range')).toHaveTextContent(`${addDays(today(), -6)} to ${today()}`)
  })

  it('is not reachable without the earnings permission', async () => {
    const calls = routes(['lab_technician'])
    open()
    await waitFor(() => expect(calls.some((c) => c.path === '/api/v1/me')).toBe(true))
    await new Promise((r) => setTimeout(r, 200))
    expect(screen.queryByTestId('kpi-opd-visits')).not.toBeInTheDocument()
    expect(calls.some((c) => c.path === '/api/v1/billing-reports/owner-kpis')).toBe(false)
  })
})
