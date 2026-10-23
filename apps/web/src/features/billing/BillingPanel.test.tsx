import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
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
})
