import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { useLocation } from 'react-router'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { EarningsPage } from './EarningsPage'

afterEach(() => vi.unstubAllGlobals())

const move = { direction: 'new' as const, pct: null }
const report = {
  from: '2026-04-01',
  to: '2026-04-30',
  grain: 'month',
  branchId: null,
  financialYear: null,
  quarter: null,
  level: 'tenant',
  tenant: card(),
  focus: card(),
  branches: [{
    branchId: ALPHA_MAIN, name: 'Alpha Main Campus', gstin: 'UNREGISTERED', deleted: false, rank: 1, sharePct: 100,
    grossBilledPaise: 0, collectedPaise: 0, netEarningsPaise: 0, outstandingPaise: 0, billCount: 0,
    periodGrowthPct: null, direction: 'new',
  }],
  trend: [{ bucket: '2026-04-01', grossBilledPaise: 0, collectedPaise: 0, netEarningsPaise: 0 }],
  doctors: [], services: [], paymentModes: [],
  ageing: { b0To30Paise: 0, b31To60Paise: 0, b61To90Paise: 0, b90PlusPaise: 0 },
  topBottom: { topBranch: null, bottomBranch: null, topDoctor: null, bottomDoctor: null },
  insights: ['No bills in this period.', 'Alpha East Clinic revenue is new vs last month'],
  gstr1: [{ gstin: 'UNREGISTERED', month: '2026-04', b2cTaxablePaise: 0, b2bTaxablePaise: 0, b2cCgstPaise: 0, b2cSgstPaise: 0, b2cIgstPaise: 0, b2bCgstPaise: 0, b2bSgstPaise: 0, b2bIgstPaise: 0, creditNoteCount: 0 }],
  gstr3b: [], hsn: [], sales: [{ invoiceNumber: 'AM-1', date: '2026-04-10', party: 'Meera Synthetic-Alpha', taxablePaise: 10, taxPaise: 1, totalPaise: 0 }],
  creditNotes: [], refunds: [], receipts: [], dayEndCash: [], truncated: false,
}

function card() {
  return {
    grossBilledPaise: 0, collectedPaise: 0, refundsPaise: 0, netEarningsPaise: 0, outstandingPaise: 0,
    discountPaise: 0, cgstPaise: 0, sgstPaise: 0, igstPaise: 0, billCount: 0, averageBillPaise: null,
    visitCount: 0, doctorCount: 0, revenuePerVisitPaise: null, revenuePerDoctorPaise: null,
    collectionEfficiencyPct: null, refundRatePct: null, discountRatePct: null,
    periodGrowthPct: null, momGrowthPct: null, yoyGrowthPct: null,
    deltas: {
      grossBilled: move, collected: move, netEarnings: move, refunds: move, billCount: move,
      averageBill: move, collectionEfficiency: move, refundRate: move, mom: move, yoy: move,
    },
  }
}

function Probe() {
  const loc = useLocation()
  return (
    <>
      <EarningsPage />
      <div data-testid="loc">{loc.search}</div>
    </>
  )
}

describe('Earnings page', () => {
  it('shows an empty period as new, keeps the URL as the source of truth, and exports the sales register', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({
        timeZone: 'Asia/Kolkata',
        accessibleBranches: [
          { id: ALPHA_MAIN, name: 'Alpha Main Campus', timeZone: 'Asia/Kolkata' },
          { id: 'a1111111-0000-4000-8000-000000000002', name: 'Alpha East Clinic', timeZone: 'Asia/Kolkata' },
        ],
      })),
      'GET /api/v1/billing-reports/earnings': () => json(report),
      'GET /api/v1/billing-reports/earnings/export': () =>
        new Response('Invoice number\n', { status: 200, headers: { 'Content-Type': 'text/csv', 'Content-Disposition': 'attachment; filename="earnings-sales.csv"' } }),
    })
    renderWithProviders(<Probe />, {
      path: '/billing/earnings?from=2026-04-01&to=2026-04-30&fy=2026&tab=overview',
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByTestId('earnings-gross')).toHaveTextContent('new')
    expect(screen.getByText('No bills in this period.')).toBeInTheDocument()
    expect(screen.getByText('Alpha East Clinic revenue is new vs last month')).toBeInTheDocument()
    expect(screen.getByTestId('earnings-trend')).toBeInTheDocument()

    fireEvent.click(screen.getAllByTestId('earnings-branch').find((el) => el.textContent?.includes('Alpha Main'))!)
    expect(screen.getByTestId('loc').textContent).toContain(`branch=${ALPHA_MAIN}`)
    expect(screen.getByTestId('loc').textContent).not.toContain('fy=')

    fireEvent.change(screen.getByLabelText('From'), { target: { value: '2026-04-02' } })
    expect(screen.getByTestId('loc').textContent).not.toContain('fy=')

    fireEvent.click(screen.getByRole('button', { name: 'Accounts' }))
    expect(await screen.findByTestId('gst-summary')).toHaveTextContent('UNREGISTERED')
    expect(screen.getByTestId('sales-register')).toHaveTextContent('Meera Synthetic-Alpha')
    fireEvent.click(screen.getByRole('button', { name: 'Sales register CSV' }))
    await vi.waitFor(() => {
      expect(calls.some((c) => c.url.includes('section=sales') && c.url.includes('format=csv'))).toBe(true)
    })
  })
})
