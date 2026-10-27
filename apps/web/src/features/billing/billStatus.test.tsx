import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, within } from '@testing-library/react'
import { Route, Routes } from 'react-router'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse } from '../../test/schedulingFixtures'
import { BILL_STATUS_LABELS, billStatusLabel } from './billStatus'
import { BillsPage } from './BillsPage'
import { BillDetailPage } from './BillDetailPage'

afterEach(() => vi.unstubAllGlobals())

// Every value allowed by the bill_status check constraint.
const STATUSES = [
  ['draft', 'Draft'],
  ['finalized', 'Finalized'],
  ['cancelled_draft', 'Cancelled draft'],
] as const

const countOf = (text: string, word: RegExp) => (text.match(word) ?? []).length

describe('billStatusLabel (#108)', () => {
  it.each(STATUSES)('labels %s as "%s"', (status, label) => expect(billStatusLabel(status)).toBe(label))
  it('covers every bill status and nothing else', () => expect(Object.keys(BILL_STATUS_LABELS).sort()).toEqual(STATUSES.map(([s]) => s).sort()))
  it('spaces underscores for an unknown status', () => expect(billStatusLabel('on_hold')).toBe('on hold'))
})

const bill = (status: string, billNo: string | null) => ({
  id: `b-${status}`, accountId: 'a1', branchId: ALPHA_MAIN, billNo, status, billKind: 'final', totalPaise: 50000, duePaise: 50000,
})

describe('Bill status shown once on list and detail (#108)', () => {
  it('list rows show each status label once (no "Draft draft")', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['billing'], ALPHA_MAIN)),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/bills': () => json([bill('draft', null), bill('finalized', 'BLR/26/0001'), bill('cancelled_draft', null)]),
    })
    renderWithProviders(
      <Routes><Route path="/billing/bills" element={<BillsPage />} /></Routes>,
      { path: `/billing/bills?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) },
    )
    const table = await screen.findByRole('table')
    await within(table).findByText('BLR/26/0001')
    const rows = within(table).getAllByRole('row').slice(1)
    expect(rows).toHaveLength(3)
    for (const [i, [, label]] of STATUSES.entries()) {
      const text = rows[i]?.textContent ?? ''
      expect(text).toContain(label)
      expect(countOf(text, /draft/gi)).toBe(label.toLowerCase().includes('draft') ? 1 : 0)
    }
  })

  it.each(STATUSES)('detail page for %s shows "%s" once', async (status, label) => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['billing'], ALPHA_MAIN)),
      'GET /api/v1/branches': () => json(branchesResponse),
      [`GET /api/v1/bills/b-${status}`]: () =>
        json({ ...bill(status, status === 'finalized' ? 'BLR/26/0001' : null), payerType: 'self', patientId: 'p1', lines: [], discounts: [],
          netPaise: 0, taxPaise: 0, discountPaise: 0, exactPaise: 0, roundOffPaise: 0 }),
    })
    renderWithProviders(
      <Routes><Route path="/billing/bills/:id" element={<BillDetailPage />} /></Routes>,
      { path: `/billing/bills/b-${status}`, auth: fakeAuthClient({ session: fakeSession() }) },
    )
    const detail = await screen.findByTestId('bill-detail')
    expect(screen.getByTestId('bill-status')).toHaveTextContent(label)
    expect(countOf(detail.textContent ?? '', /draft/gi)).toBe(label.toLowerCase().includes('draft') ? 1 : 0)
  })
})
