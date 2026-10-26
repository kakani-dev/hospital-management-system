import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { BillingPanel } from './BillingPanel'
import { fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'
import type { BillDocument } from '../../lib/api/types'

afterEach(() => vi.unstubAllGlobals())

const bill = (overrides: Partial<BillDocument> = {}): BillDocument => ({
  id: 'bill-1',
  billNo: null,
  status: 'draft',
  billKind: 'final',
  payerType: 'self',
  accountId: 'acct-1',
  patientId: 'patient-1',
  branchId: 'branch-1',
  lines: [
    {
      id: 'line-1',
      lineNo: 1,
      serviceItemId: 'item-1',
      code: 'CONSULT',
      name: 'OP consultation',
      quantity: 1,
      unitPricePaise: 50000,
      taxRateBp: 0,
      netPaise: 50000,
      taxPaise: 0,
      practitionerId: null,
    },
  ],
  discounts: [],
  netPaise: 50000,
  taxPaise: 0,
  discountPaise: 0,
  exactPaise: 50000,
  roundOffPaise: 0,
  totalPaise: 50000,
  duePaise: 50000,
  ...overrides,
})

describe('BillingPanel', () => {
  it('raises an OP consultation and shows the rounded total', async () => {
    stubFetch({
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'POST /api/v1/bills/bill-1/lines': () => json(bill()),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByText('OP consultation')).toBeInTheDocument()
    expect(screen.getByTestId('bill-total')).toHaveTextContent('₹500.00')
    expect(screen.getByTestId('collect-cash')).toHaveFocus()
    expect(screen.getByTestId('finalize-bill')).toHaveTextContent('Close bill')
  })

  it('searches the catalog and adds the service on Enter', async () => {
    const calls = stubFetch({
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'POST /api/v1/bills/bill-1/lines': (_url, init) => {
        const body = JSON.parse(String(init?.body)) as { serviceItemId?: string }
        if (body.serviceItemId) {
          return json(bill({
            lines: [
              bill().lines[0]!,
              { ...bill().lines[0]!, id: 'line-2', lineNo: 2, serviceItemId: 'dress-1', code: 'DRESS', name: 'Wound dressing', unitPricePaise: 15000, netPaise: 15000 },
            ],
            totalPaise: 65000,
            duePaise: 65000,
            netPaise: 65000,
            exactPaise: 65000,
          }))
        }
        return json(bill())
      },
      'GET /api/v1/service-items': () => json([
        { id: 'dress-1', code: 'DRESS', name: 'Wound dressing', category: 'procedure', taxCodeId: 'tax-1', sacHsnCode: '9993', taxRateBp: 0, isExempt: true, isActive: true, isStockTracked: false, hospitalPricePaise: 15000 },
      ]),
      'GET /api/v1/practitioners': () => json([]),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await screen.findByText('OP consultation')
    await user.type(screen.getByLabelText('Find a service'), 'dress')
    expect(await screen.findByRole('option', { name: /Wound dressing/ })).toBeInTheDocument()
    await user.keyboard('{Enter}')
    expect(await screen.findAllByTestId('bill-line')).toHaveLength(2)
    const added = calls.find((call) => call.method === 'POST' && call.path === '/api/v1/bills/bill-1/lines' && (call.body as { serviceItemId?: string }).serviceItemId)
    expect(added?.body).toEqual({ serviceItemId: 'dress-1' })
  })

  it('collects the consultation, then a procedure, on the same open bill', async () => {
    let payments = 0
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({ patientId: 'patient-1', advancePaise: 0, bills: [] }),
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'POST /api/v1/bills/bill-1/lines': (_url, init) => {
        const body = JSON.parse(String(init?.body)) as { serviceItemId?: string }
        if (body.serviceItemId) {
          return json(bill({
            allocatedPaise: 50000,
            lines: [
              { ...bill().lines[0]!, locked: true },
              { ...bill().lines[0]!, id: 'line-2', lineNo: 2, serviceItemId: 'dress-1', code: 'DRESS', name: 'Wound dressing', unitPricePaise: 15000, netPaise: 15000, locked: false },
            ],
            totalPaise: 65000,
            duePaise: 15000,
            netPaise: 65000,
            exactPaise: 65000,
          }))
        }
        return json(bill())
      },
      'POST /api/v1/counter-sessions/ensure': () => json({ id: 'sess-1', opened: true }),
      'POST /api/v1/payments': () => {
        payments += 1
        const amount = payments === 1 ? 50000 : 15000
        return json({
          id: `rcpt-${payments}`,
          receiptNo: 'OPR0000000000001',
          kind: 'payment',
          amountPaise: amount,
          accountId: 'acct-1',
          counterSessionId: 'sess-1',
          tenders: [{ mode: 'cash', amountPaise: amount, reference: null }],
          allocations: [{ billId: 'bill-1', amountPaise: amount }],
        })
      },
      'GET /api/v1/bills/bill-1': () => json(payments === 1
        ? bill({ duePaise: 0, allocatedPaise: 50000, lines: [{ ...bill().lines[0]!, locked: true }] })
        : bill({
            duePaise: 0,
            allocatedPaise: 65000,
            totalPaise: 65000,
            netPaise: 65000,
            exactPaise: 65000,
            lines: [
              { ...bill().lines[0]!, locked: true },
              { ...bill().lines[0]!, id: 'line-2', lineNo: 2, name: 'Wound dressing', unitPricePaise: 15000, netPaise: 15000, locked: true },
            ],
          })),
      'GET /api/v1/service-items': () => json([
        { id: 'dress-1', code: 'DRESS', name: 'Wound dressing', category: 'procedure', taxCodeId: 'tax-1', sacHsnCode: '9993', taxRateBp: 0, isExempt: true, isActive: true, isStockTracked: false, hospitalPricePaise: 15000 },
      ]),
      'GET /api/v1/practitioners': () => json([]),
      'POST /api/v1/bills/bill-1/finalize': () => json(bill({
        status: 'finalized',
        billNo: 'OPB0000000000001',
        duePaise: 0,
        allocatedPaise: 65000,
        totalPaise: 65000,
        netPaise: 65000,
        exactPaise: 65000,
        lines: [
          { ...bill().lines[0]!, locked: true },
          { ...bill().lines[0]!, id: 'line-2', lineNo: 2, name: 'Wound dressing', unitPricePaise: 15000, netPaise: 15000, locked: true },
        ],
      })),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('collect-cash'))
    expect(await screen.findByText('Collected. Add anything else, then close the bill.')).toBeInTheDocument()
    expect(screen.queryByTestId('paid-status')).not.toBeInTheDocument()
    expect(screen.getByText('Paid')).toBeInTheDocument()

    await user.type(screen.getByLabelText('Find a service'), 'dress')
    expect(await screen.findByRole('option', { name: /Wound dressing/ })).toBeInTheDocument()
    await user.keyboard('{Enter}')
    expect(await screen.findByTestId('bill-due')).toHaveTextContent('₹150.00')
    await user.click(screen.getByTestId('collect-cash'))
    expect(await screen.findByText('Collected. Add anything else, then close the bill.')).toBeInTheDocument()
    await user.click(screen.getByTestId('finalize-bill'))
    expect(await screen.findByTestId('paid-status')).toHaveTextContent('Paid')

    const pays = calls.filter((call) => call.method === 'POST' && call.path === '/api/v1/payments')
    expect(pays).toHaveLength(2)
    expect(pays[0]?.body).toMatchObject({
      counterSessionId: 'sess-1',
      tenders: [{ mode: 'cash', amountPaise: 50000 }],
      allocations: [{ billId: 'bill-1', amountPaise: 50000 }],
    })
    expect(pays[1]?.body).toMatchObject({
      counterSessionId: 'sess-1',
      tenders: [{ mode: 'cash', amountPaise: 15000 }],
      allocations: [{ billId: 'bill-1', amountPaise: 15000 }],
    })
    expect(calls.some((call) => call.method === 'POST' && call.path === '/api/v1/counter-sessions/ensure')).toBe(true)
  })

  it('applies an existing patient advance to the open bill', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({ patientId: 'patient-1', advancePaise: 20000, bills: [] }),
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'POST /api/v1/bills/bill-1/lines': () => json(bill()),
      'POST /api/v1/bills/bill-1/advances': () => json(bill({ duePaise: 30000, allocatedPaise: 20000 })),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('apply-advance'))
    expect(await screen.findByTestId('bill-due')).toHaveTextContent('₹300.00')
    const applied = calls.find((call) => call.path === '/api/v1/bills/bill-1/advances')
    expect(applied?.body).toEqual({ amountPaise: 20000 })
  })

  it('reuses the check-in draft instead of opening another bill', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-9', accountId: 'acct-9', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-9': () => json(bill({ id: 'bill-9', accountId: 'acct-9' })),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByText('OP consultation')).toBeInTheDocument()
    expect(calls.some((call) => call.method === 'POST' && call.path === '/api/v1/accounts')).toBe(false)
  })

  it('shows why a cash collection failed when the request never reaches the server', async () => {
    stubFetch({
      'POST /api/v1/accounts': () => json(bill()),
      'POST /api/v1/counter-sessions/ensure': () => json({ id: 'sess-1', businessDate: '2026-10-26', opened: false }),
      'POST /api/v1/payments': () => {
        throw new TypeError('Failed to fetch')
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('collect-cash'))
    expect(await screen.findByText('The server could not be reached.')).toBeInTheDocument()
    expect(screen.queryByText('The bill could not be updated. Try again.')).not.toBeInTheDocument()
  })

  it('shows the counter-session message when no session can be opened', async () => {
    const calls = stubFetch({
      'POST /api/v1/accounts': () => json(bill()),
      'POST /api/v1/counter-sessions/ensure': () => json({ id: null }),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('collect-cash'))
    expect(await screen.findByText('Open a counter session before taking cash.')).toBeInTheDocument()
    expect(calls.some((call) => call.path === '/api/v1/payments')).toBe(false)
  })

  it('labels the discount box so it is not an empty grey field', async () => {
    stubFetch({ 'POST /api/v1/accounts': () => json(bill()) })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByPlaceholderText('Discount ₹')).toHaveAccessibleName('Discount rupees')
  })
})
