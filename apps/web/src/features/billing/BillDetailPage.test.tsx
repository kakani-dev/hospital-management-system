import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import { Route, Routes } from 'react-router'
import { BillDetailPage } from './BillDetailPage'
import { fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const doc = (discountPaise: number) => ({
  id: 'bill-1', billNo: 'DEMOB1', status: 'final', billKind: 'final', payerType: 'self', accountId: 'a', patientId: 'p', branchId: 'b',
  lines: [{ id: 'l1', name: 'OP consultation', netPaise: 20000, taxPaise: 0, locked: true }],
  discounts: [], netPaise: 20000 - discountPaise, taxPaise: 0, discountPaise, exactPaise: 20000 - discountPaise, roundOffPaise: 0,
  totalPaise: 20000 - discountPaise, duePaise: 0,
})

const show = (discountPaise: number) => {
  stubFetch({ 'GET /api/v1/bills/bill-1': () => json(doc(discountPaise)) })
  renderWithProviders(<Routes><Route path="/billing/bills/:id" element={<BillDetailPage />} /></Routes>, {
    path: '/billing/bills/bill-1', auth: fakeAuthClient({ session: fakeSession() }),
  })
}

describe('BillDetailPage discount', () => {
  it('shows the discount line on the printed bill when a discount was applied', async () => {
    show(4000)
    expect(await screen.findByTestId('billing-bill-discount')).toHaveTextContent('40.00')
  })

  it('shows no discount line when there is none', async () => {
    show(0)
    await screen.findByTestId('bill-detail')
    expect(screen.queryByTestId('billing-bill-discount')).toBeNull()
  })
})

describe('BillDetailPage free follow-up note', () => {
  it('prints the free follow-up note under a zero consult line and keeps other lines charged', async () => {
    const base = doc(0)
    stubFetch({
      'GET /api/v1/bills/bill-1': () => json({
        ...base,
        lines: [
          { id: 'l1', name: 'OP consultation', netPaise: 0, taxPaise: 0, locked: false, note: 'Free follow-up (within 7 days of 1 Oct 2026)' },
          { id: 'l2', name: 'CBC (synthetic)', netPaise: 30000, taxPaise: 0, locked: false, note: null },
        ],
        netPaise: 30000, exactPaise: 30000, totalPaise: 30000, duePaise: 30000,
      }),
    })
    renderWithProviders(<Routes><Route path="/billing/bills/:id" element={<BillDetailPage />} /></Routes>, {
      path: '/billing/bills/bill-1', auth: fakeAuthClient({ session: fakeSession() }),
    })
    const notes = await screen.findAllByTestId('billing-bill-line-note')
    expect(notes).toHaveLength(1)
    expect(notes[0]).toHaveTextContent('Free follow-up (within 7 days of 1 Oct 2026)')
    expect(screen.getByText('CBC (synthetic)').parentElement).toHaveTextContent('300.00')
  })
})
