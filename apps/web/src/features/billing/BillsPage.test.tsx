import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import { Route, Routes } from 'react-router'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse } from '../../test/schedulingFixtures'
import { BillsPage } from './BillsPage'

afterEach(() => vi.unstubAllGlobals())

const base = { billKind: 'final', patientId: 'p1', branchId: ALPHA_MAIN, totalPaise: 50000, duePaise: 50000, createdOn: '2026-10-30T05:00:00Z' }

describe('Bills list (#124)', () => {
  it('shows patient name and MRN so drafts can be told apart, and readable statuses', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_MAIN)),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/bills': () =>
        json([
          { ...base, id: 'b1', billNo: null, status: 'draft', patientName: 'Zz-QA Asha Rao', patientMrn: 'MRN-0001' },
          { ...base, id: 'b2', billNo: null, status: 'cancelled_draft', patientName: 'Zz-QA Ravi Kumar', patientMrn: 'MRN-0002' },
          { ...base, id: 'b3', billNo: 'DEMOB9', status: 'finalized', patientName: null, patientMrn: null },
        ]),
    })
    renderWithProviders(
      <Routes>
        <Route path="/billing/bills" element={<BillsPage />} />
      </Routes>,
      { path: `/billing/bills?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) },
    )
    const patients = await screen.findAllByTestId('billing-bills-row-patient')
    expect(patients[0]).toHaveTextContent('Zz-QA Asha Rao')
    expect(patients[0]).toHaveTextContent('MRN MRN-0001')
    expect(patients[1]).toHaveTextContent('Zz-QA Ravi Kumar')
    expect(patients[2]).toHaveTextContent('Unknown patient')
    expect(screen.getAllByTestId('billing-bills-row-mrn')).toHaveLength(2)
    const statuses = screen.getAllByTestId('billing-bills-row-status')
    expect(statuses[1]).not.toHaveTextContent('cancelled_draft')
  })
})
