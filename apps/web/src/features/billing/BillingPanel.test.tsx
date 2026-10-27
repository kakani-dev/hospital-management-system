import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { BillingPanel } from './BillingPanel'
import { fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'
import type { BillDocument } from '../../lib/api/types'
import { useLocation } from 'react-router'

function Where() {
  const location = useLocation()
  return <span data-testid="test-location">{location.pathname + location.search}</span>
}

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
    await userEvent.setup().click(await screen.findByTestId('billing-panel-add-consult'))
    expect(await screen.findByText('OP consultation')).toBeInTheDocument()
    expect(screen.getByTestId('bill-total')).toHaveTextContent('₹500.00')
    expect(await screen.findByTestId('collect-cash')).toBeInTheDocument()
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
    await userEvent.setup().click(await screen.findByTestId('billing-panel-add-consult'))
    await screen.findByText('OP consultation')
    await user.type(screen.getByLabelText('Find a service'), 'dress')
    expect(await screen.findByRole('option', { name: /Wound dressing/ })).toBeInTheDocument()
    await user.keyboard('{Enter}')
    await screen.findByText('Wound dressing', { selector: '[data-testid="bill-line"] *' })
    expect(screen.getAllByTestId('bill-line')).toHaveLength(2)
    const added = calls.find((call) => call.method === 'POST' && call.path === '/api/v1/bills/bill-1/lines' && (call.body as { serviceItemId?: string }).serviceItemId)
    expect(added?.body).toEqual({ serviceItemId: 'dress-1', quantity: 1 })
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
    await userEvent.setup().click(await screen.findByTestId('billing-panel-add-consult'))
    await user.click(await screen.findByTestId('billing-collect-close-after'))
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
    expect(screen.getByTestId('billing-panel-view-receipt')).toHaveAttribute('href', expect.stringMatching(/^\/billing\/receipts\//))
    expect(screen.getByTestId('billing-panel-print-receipt')).toHaveAttribute('href', expect.stringMatching(/\?print=1$/))

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
    await userEvent.setup().click(await screen.findByTestId('billing-panel-add-consult'))
    await user.click(await screen.findByTestId('apply-advance'))
    expect(await screen.findByTestId('bill-due')).toHaveTextContent('₹300.00')
    const applied = calls.find((call) => call.path === '/api/v1/bills/bill-1/advances')
    expect(applied?.body).toEqual({ amountPaise: 20000 })
  })

  it('does not open a bill or add a consultation on its own (#164)', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({ patientId: 'patient-1', advancePaise: 0, bills: [] }),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByTestId('billing-panel-empty')).toBeInTheDocument()
    expect(screen.getByTestId('billing-panel-add-consult')).toBeInTheDocument()
    expect(calls.some((call) => call.method === 'POST')).toBe(false)
  })

  it('opens an empty bill for other services without a consultation line (#164)', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({ patientId: 'patient-1', advancePaise: 0, bills: [] }),
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'GET /api/v1/service-items': () => json([]),
      'GET /api/v1/practitioners': () => json([]),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('billing-panel-other-services'))
    expect(await screen.findByLabelText('Find a service')).toBeInTheDocument()
    expect(calls.some((call) => call.path === '/api/v1/bills/bill-1/lines')).toBe(false)
  })

  it('adds CONSULT without a doctor so the server picks the visit doctor (#165)', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({ patientId: 'patient-1', advancePaise: 0, bills: [] }),
      'POST /api/v1/accounts': () => json(bill({ lines: [], totalPaise: 0, duePaise: 0, netPaise: 0, exactPaise: 0 })),
      'POST /api/v1/bills/bill-1/lines': () => json(bill()),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await userEvent.setup().click(await screen.findByTestId('billing-panel-add-consult'))
    expect(await screen.findByText('OP consultation')).toBeInTheDocument()
    const added = calls.find((call) => call.path === '/api/v1/bills/bill-1/lines')
    expect(added?.body).toEqual({ code: 'CONSULT' })
  })

  it('lists each tender of a split receipt and only the advance applied (#166)', async () => {
    stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 20000,
        bills: [{ id: 'bill-9', accountId: 'acct-9', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 0 }],
      }),
      'GET /api/v1/bills/bill-9': () => json(bill({
        id: 'bill-9', accountId: 'acct-9', duePaise: 0,
        payments: [
          { id: 'p1', receiptNo: 'R1', kind: 'payment', amountPaise: 20000, appliedPaise: 20000, refundedPaise: 0, mode: 'split',
            tenders: [{ mode: 'cash', amountPaise: 12000 }, { mode: 'upi', amountPaise: 8000 }] },
          { id: 'p2', receiptNo: 'R2', kind: 'advance', amountPaise: 50000, appliedPaise: 30000, advanceBalancePaise: 20000, refundedPaise: 0, mode: 'upi',
            tenders: [{ mode: 'upi', amountPaise: 50000 }] },
        ],
      })),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    const rows = await screen.findAllByTestId('billing-panel-payment')
    expect(rows[0]).toHaveTextContent('Split: CASH ₹120.00 + UPI ₹80.00')
    expect(rows[0]).toHaveTextContent('₹200.00')
    expect(rows[1]).toHaveTextContent('Advance')
    expect(rows[1]).toHaveTextContent('₹300.00')
    expect(screen.getByTestId('billing-panel-payment-advance-left')).toHaveTextContent('₹200.00 left')
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
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(bill()),
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
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(bill()),
      'POST /api/v1/counter-sessions/ensure': () => json({ id: null }),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.click(await screen.findByTestId('collect-cash'))
    expect(await screen.findByText('Open a counter session before taking money.')).toBeInTheDocument()
    expect(calls.some((call) => call.path === '/api/v1/payments')).toBe(false)
  })

  it('labels the discount box so it is not an empty grey field', async () => {
    stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(bill()),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByPlaceholderText('Discount ₹')).toHaveAccessibleName('Discount rupees')
  })

  const summary = () => json({
    patientId: 'patient-1',
    advancePaise: 0,
    bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
  })

  it('clears the discount box after success, shows the discount line and cannot apply twice', async () => {
    const user = userEvent.setup()
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': summary,
      'GET /api/v1/bills/bill-1': () => json(bill()),
      'POST /api/v1/bills/bill-1/discounts': () => json(bill({ discountPaise: 2000, totalPaise: 48000, duePaise: 48000 })),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    const input = await screen.findByTestId('billing-panel-discount-input')
    expect(screen.queryByTestId('billing-panel-discount')).toBeNull()
    await user.type(input, '20')
    await user.click(screen.getByTestId('billing-panel-discount-submit'))
    expect(await screen.findByTestId('billing-panel-discount')).toHaveTextContent('20.00')
    expect(input).toHaveValue('')
    expect(screen.getByTestId('billing-panel-discount-submit')).toBeDisabled()
    await user.click(screen.getByTestId('billing-panel-discount-submit'))
    expect(calls.filter((call) => call.path.endsWith('/discounts'))).toHaveLength(1)
  })

  it('clears the discount box when the discount goes for approval', async () => {
    const user = userEvent.setup()
    stubFetch({
      'GET /api/v1/accounts/patient-1/summary': summary,
      'GET /api/v1/bills/bill-1': () => json(bill()),
      'POST /api/v1/bills/bill-1/discounts': () => json({ approvalId: 'ap-1', status: 'pending' }),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    const input = await screen.findByTestId('billing-panel-discount-input')
    await user.type(input, '900')
    await user.click(screen.getByTestId('billing-panel-discount-submit'))
    expect(await screen.findByText(/Someone else has to approve it/)).toBeInTheDocument()
    expect(input).toHaveValue('')
  })

  it('does not allow a zero or non-numeric discount', async () => {
    const user = userEvent.setup()
    stubFetch({
      'GET /api/v1/accounts/patient-1/summary': summary,
      'GET /api/v1/bills/bill-1': () => json(bill()),
    })
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    const input = await screen.findByTestId('billing-panel-discount-input')
    await user.type(input, '0')
    expect(screen.getByTestId('billing-panel-discount-submit')).toBeDisabled()
    await user.clear(input); await user.type(input, 'abc')
    expect(screen.getByTestId('billing-panel-discount-submit')).toBeDisabled()
  })

  it('shows the patient header, collects split payment on Enter, closes and prints in the same tab (#172, #174, #180)', async () => {
    const open = vi.fn()
    vi.stubGlobal('open', open)
    const calls = stubFetch({
      'GET /api/v1/patients/patient-1': () => json({ id: 'patient-1', mrn: 'MRN-ZZ1', firstName: 'Qa', lastName: 'Zz-Patient' }),
      'GET /api/v1/practitioners': () => json([{ id: 'doc-1', displayName: 'Dr Zz-QA' }]),
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(calls.some((c) => c.path === '/api/v1/payments')
        ? bill({ duePaise: 0, allocatedPaise: 50000, lines: [{ ...bill().lines[0]!, practitionerId: 'doc-1' }] })
        : bill({ lines: [{ ...bill().lines[0]!, practitionerId: 'doc-1' }] })),
      'POST /api/v1/counter-sessions/ensure': () => json({ id: 'sess-1', opened: false }),
      'POST /api/v1/payments': () => json({ id: 'rcpt-9', receiptNo: 'R9', kind: 'payment', amountPaise: 50000, accountId: 'acct-1', counterSessionId: 'sess-1', tenders: [], allocations: [] }),
      'POST /api/v1/bills/bill-1/finalize': () => json(bill({ status: 'finalized', billNo: 'B1', duePaise: 0, allocatedPaise: 50000 })),
    })
    const user = userEvent.setup()
    renderWithProviders(<><BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} /><Where /></>, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    expect(await screen.findByTestId('billing-panel-patient-name')).toHaveTextContent('Zz-Patient, Qa')
    expect(screen.getByTestId('billing-panel-patient-mrn')).toHaveTextContent('MRN-ZZ1')
    expect(await screen.findByTestId('billing-panel-patient-doctor')).toHaveTextContent('Dr Zz-QA')
    await user.click(await screen.findByTestId('billing-collect-mode-split'))
    await user.type(screen.getByTestId('billing-collect-received'), '300{Enter}')
    expect(await screen.findByTestId('paid-status')).toHaveTextContent('Paid')
    const pay = calls.find((c) => c.path === '/api/v1/payments')
    expect(pay?.body).toMatchObject({
      tenders: [{ mode: 'cash', amountPaise: 30000 }, { mode: 'upi', amountPaise: 20000 }],
      allocations: [{ billId: 'bill-1', amountPaise: 50000 }],
    })
    expect(calls.some((c) => c.path === '/api/v1/bills/bill-1/finalize')).toBe(true)
    // #180: no new tab (it would start signed out); the receipt prints in this tab.
    expect(await screen.findByTestId('test-location')).toHaveTextContent('/billing/receipts/rcpt-9?print=1')
    expect(open).not.toHaveBeenCalled()
  })

  it('shows change due for cash and records only the due', async () => {
    stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(bill()),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.type(await screen.findByTestId('billing-collect-received'), '2000')
    expect(screen.getByTestId('billing-collect-change')).toHaveTextContent('₹1,500.00')
    expect(screen.getByTestId('collect-cash')).toHaveTextContent('Collect ₹500.00')
  })

  it('adds a quantity typed after the service name ("ecg 2") (#173)', async () => {
    const calls = stubFetch({
      'GET /api/v1/accounts/patient-1/summary': () => json({
        patientId: 'patient-1',
        advancePaise: 0,
        bills: [{ id: 'bill-1', accountId: 'acct-1', branchId: 'branch-1', billNo: null, status: 'draft', billKind: 'final', totalPaise: 50000, duePaise: 50000 }],
      }),
      'GET /api/v1/bills/bill-1': () => json(bill()),
      'GET /api/v1/service-items': () => json([
        { id: 'ecg-1', code: 'ECG', name: 'ECG', category: 'procedure', taxCodeId: 'tax-1', sacHsnCode: '9993', taxRateBp: 0, isExempt: true, isActive: true, isStockTracked: false, hospitalPricePaise: 20000 },
      ]),
      'GET /api/v1/practitioners': () => json([]),
      'POST /api/v1/bills/bill-1/lines': () => json(bill()),
    })
    const user = userEvent.setup()
    renderWithProviders(<BillingPanel patientId="patient-1" branchId="branch-1" onBack={() => {}} />, {
      auth: fakeAuthClient({ session: fakeSession() }),
    })
    await user.type(await screen.findByLabelText('Find a service'), 'ecg 2')
    expect(await screen.findByRole('option', { name: /ECG/ })).toBeInTheDocument()
    expect(screen.getByTestId('billing-drawer-service-qty')).toHaveValue('2')
    await user.keyboard('{Enter}')
    await vi.waitFor(() => expect(calls.some((c) => c.path === '/api/v1/bills/bill-1/lines')).toBe(true))
    const added = calls.find((c) => c.path === '/api/v1/bills/bill-1/lines')
    expect(added?.body).toEqual({ serviceItemId: 'ecg-1', quantity: 2 })
    expect(calls.find((c) => c.path === '/api/v1/service-items')?.url).toContain('q=ecg')
  })
})
