import { describe, expect, it } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

const asha = { id: 'p1', mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female', registeredBranchId: ALPHA_MAIN }

describe('previous results stay on screen while the next query loads (keepPreviousData)', () => {
  it('the patient table keeps the last rows (dimmed, aria-busy) instead of a "Loading…" row', async () => {
    let release: (() => void) | null = null
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [asha], page: 1, pageSize: 25, totalCount: 1 }),
      'POST /api/v1/patients/search': () =>
        new Promise<Response>((resolve) => (release = () => resolve(json({ items: [], page: 1, pageSize: 25, totalCount: 0 })))),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-row')).toHaveTextContent('ALP-0001')

    await user.type(screen.getByLabelText('Search patients'), 'zzz')
    await waitFor(() => expect(release).not.toBeNull())
    // Search in flight: old row still visible, marked stale; no blanking "Loading…" row.
    expect(screen.getByTestId('patient-row')).toHaveTextContent('ALP-0001')
    expect(screen.getByTestId('patient-row').closest('tbody')).toHaveAttribute('data-stale', 'true')
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument()

    release!()
    expect(await screen.findByTestId('patients-empty')).toBeInTheDocument()
    expect(screen.getByTestId('patients-empty').closest('tbody')).not.toHaveAttribute('data-stale')
  })
})
