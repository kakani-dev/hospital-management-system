import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { PATIENT_ID, branchesResponse, patientDetail } from '../../test/schedulingFixtures'

const me = meWithRoles(['billing'], ALPHA_MAIN)
const tender = (mode: string, amountPaise: number) => ({ mode, amountPaise, reference: null, paymentAccountLabel: null, payeeVpa: null })
const receipt = (tenders: unknown[], collectedBy: string) => ({
  id: 'r1', receiptNo: 'RCPT-1', kind: 'payment', amountPaise: 70000, accountId: 'a1', counterSessionId: null, approvalId: null,
  tenders, allocations: [{ billId: 'b1', amountPaise: 70000 }], receivedAt: '2026-10-27T06:30:00Z', collectedBy,
})
const bill = {
  id: 'b1', billNo: 'BILL-1', status: 'final', billKind: 'final', patientId: PATIENT_ID, totalPaise: 70000,
  lines: [{ id: 'l1', name: 'Consultation (synthetic)', quantity: 1, netPaise: 70000, taxPaise: 0 }],
  supplier: { name: 'Zz-QA Synthetic Hospital', gstin: '29ABCDE1234F1Z5', address: 'Synthetic Rd', stateCode: '29' },
  payments: [],
}

function routes(r: unknown) {
  return stubFetch({
    'GET /api/v1/me': () => json(me),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/receipts/r1': () => json(r),
    'GET /api/v1/bills/b1': () => json(bill),
    [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(patientDetail),
  })
}

afterEach(() => vi.restoreAllMocks())

describe('ReceiptPage (#183)', () => {
  it('shows hospital, GSTIN, patient + MRN, bill and receipt no, date, lines, total, paid, mode and collector; prints once when loaded', async () => {
    routes(receipt([tender('cash', 70000)], me.userId))
    const print = vi.spyOn(window, 'print').mockImplementation(() => {})
    renderWithProviders(<App />, { path: '/billing/receipts/r1?print=1', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('billing-receipt-patient')).toHaveTextContent(`MRN ${patientDetail.mrn}`)
    expect(screen.getByTestId('billing-receipt-hospital')).toHaveTextContent('Zz-QA Synthetic Hospital')
    expect(screen.getByTestId('billing-receipt-gstin')).toHaveTextContent('29ABCDE1234F1Z5')
    expect(screen.getByTestId('billing-receipt-bill-no')).toHaveTextContent('BILL-1')
    expect(screen.getByTestId('billing-receipt-no')).toHaveTextContent('RCPT-1')
    expect(screen.getByTestId('billing-receipt-date')).toHaveTextContent('2026')
    expect(screen.getByTestId('billing-receipt-lines')).toHaveTextContent('Consultation (synthetic)')
    expect(screen.getByTestId('billing-receipt-bill-total')).toHaveTextContent('₹700.00')
    expect(screen.getByTestId('billing-receipt-amount')).toHaveTextContent('₹700.00')
    expect(screen.getByTestId('billing-receipt-tenders')).toHaveTextContent('Mode: Cash')
    expect(screen.getByTestId('billing-receipt-collector')).toHaveTextContent(me.email!)
    expect(screen.getByTestId('receipt')).toHaveAttribute('data-print-area')
    await waitFor(() => expect(print).toHaveBeenCalledTimes(1))
  })

  it('labels a split payment and shows a short staff id for another collector', async () => {
    routes(receipt([tender('cash', 20000), tender('upi', 50000)], '0f0e0d0c-0000-4000-8000-000000000001'))
    vi.spyOn(window, 'print').mockImplementation(() => {})
    renderWithProviders(<App />, { path: '/billing/receipts/r1', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('billing-receipt-tenders')).toHaveTextContent('Mode: Split')
    expect(screen.getByTestId('billing-receipt-tenders')).toHaveTextContent('UPI')
    expect(screen.getByTestId('billing-receipt-collector')).toHaveTextContent('Staff 0f0e0d0c')
    expect(window.print).not.toHaveBeenCalled()
  })
})
