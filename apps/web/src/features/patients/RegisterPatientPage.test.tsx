import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const listPage = { items: [], page: 1, pageSize: 25, totalCount: 0 }

describe('RegisterPatientPage', () => {
  it('validates input client-side', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: /register patient/i }))
    expect(await screen.findByText(/mrn is required/i)).toBeInTheDocument()
    expect(screen.getByText(/first name is required/i)).toBeInTheDocument()
  })

  it('submits the patient with the chosen branch and never a tenant id', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
      'POST /api/v1/patients': (_u, init) => json({ id: 'p1', sex: 'female', dateOfBirth: null, ...JSON.parse(String(init.body)) }, 201),
      'GET /api/v1/patients': () => json(listPage),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })

    await user.type(await screen.findByLabelText('MRN'), 'NEW-0001')
    await user.type(screen.getByLabelText('First name'), 'Asha')
    await user.type(screen.getByLabelText('Last name'), 'Synthetic')
    await user.selectOptions(screen.getByLabelText('Registered branch'), ALPHA_EAST)
    await user.selectOptions(screen.getByLabelText('Sex'), 'female')
    await user.click(screen.getByRole('button', { name: /register patient/i }))

    expect(await screen.findByText(/patient NEW-0001 registered/i)).toBeInTheDocument()
    const body = calls.find((c) => c.method === 'POST')!.body as Record<string, unknown>
    expect(body).toMatchObject({ mrn: 'NEW-0001', firstName: 'Asha', registeredBranchId: ALPHA_EAST, sex: 'female', dateOfBirth: null })
    expect(body).not.toHaveProperty('tenantId')
  })

  it('maps a 409 to a duplicate-MRN field error', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
      'POST /api/v1/patients': () => json({ title: 'Duplicate MRN', status: 409 }, 409),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.type(await screen.findByLabelText('MRN'), 'ALP-0001')
    await user.type(screen.getByLabelText('First name'), 'Dup')
    await user.type(screen.getByLabelText('Last name'), 'Licate')
    await user.click(screen.getByRole('button', { name: /register patient/i }))
    expect(await screen.findByText(/already exists in this hospital/i)).toBeInTheDocument()
  })
})
