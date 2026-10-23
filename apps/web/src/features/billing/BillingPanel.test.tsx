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
    expect(screen.getByTestId('finalize-bill')).toHaveFocus()
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
})
