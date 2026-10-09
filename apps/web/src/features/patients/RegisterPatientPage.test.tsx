import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

import { restoreWorkstation, workstationAt } from '../../test/timeZones'

afterEach(() => {
  restoreWorkstation()
  vi.unstubAllGlobals()
})

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
    const body = calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body as Record<string, unknown>
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

describe('RegisterPatientPage duplicate warning', () => {
  const match = {
    id: 'aa000000-0000-4000-8000-000000000001',
    mrn: 'ALP-0001',
    firstName: 'Asha',
    lastName: 'Synthetic',
    dateOfBirth: '1990-01-01',
    sex: 'female',
    phone: '+91 98450 00001',
    registeredBranchId: ALPHA_MAIN,
    matchReasons: ['name_dob', 'phone'],
  }

  async function fillForm(user: ReturnType<typeof userEvent.setup>) {
    await user.type(await screen.findByLabelText('MRN'), 'NEW-0002')
    await user.type(screen.getByLabelText('First name'), ' Asha ')
    await user.type(screen.getByLabelText('Last name'), 'Synthetic')
    await user.type(screen.getByLabelText('Date of birth'), '1990-01-01')
    await user.type(screen.getByLabelText('Phone (optional)'), '+91 98450 00001')
    await user.click(screen.getByRole('button', { name: /register patient/i }))
  }

  it('checks for possible matches at submit and lets the user register anyway', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [match] }),
      'POST /api/v1/patients': (_u, init) => json({ id: 'p2', ...JSON.parse(String(init.body)) }, 201),
      'GET /api/v1/patients': () => json(listPage),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
    await fillForm(user)

    const warning = await screen.findByTestId('duplicate-warning')
    expect(warning).toHaveTextContent('ALP-0001')
    expect(warning).toHaveTextContent('same name and date of birth and same phone number')
    expect(screen.getByRole('link', { name: 'Open existing record ALP-0001' })).toHaveAttribute('href', `/patients/${match.id}`)
    expect(calls.some((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toBe(false)
    expect(calls.find((c) => c.path === '/api/v1/patients/duplicates')!.body).toEqual({
      firstName: 'Asha',
      lastName: 'Synthetic',
      dateOfBirth: '1990-01-01',
      phone: '+91 98450 00001',
    })

    await user.click(screen.getByRole('button', { name: 'Register anyway' }))
    expect(await screen.findByText(/patient NEW-0002 registered/i)).toBeInTheDocument()
    expect(calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toHaveLength(1)
  })

  it('opens the existing record instead of registering', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [match] }),
      [`GET /api/v1/patients/${match.id}`]: () => json({ ...match, email: null }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
    await fillForm(user)
    await user.click(await screen.findByRole('link', { name: 'Open existing record ALP-0001' }))
    expect(await screen.findByTestId('patient-details')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toBe(false)
  })

  it('registers straight away when there are no matches', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [] }),
      'POST /api/v1/patients': (_u, init) => json({ id: 'p2', ...JSON.parse(String(init.body)) }, 201),
      'GET /api/v1/patients': () => json(listPage),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
    await fillForm(user)
    expect(await screen.findByText(/patient NEW-0002 registered/i)).toBeInTheDocument()
    expect(screen.queryByTestId('duplicate-warning')).not.toBeInTheDocument()
    expect(calls.map((c) => `${c.method} ${c.path}`)).toContain('POST /api/v1/patients/duplicates')
  })

  describe('date of birth uses the registering branch\'s time zone (as the API does)', () => {
    // Workstation in New York (still 2026-10-06), Alpha Main in India (already 2026-10-07 00:30),
    // Alpha East in New York.
    const branches = [
      { id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true },
      { id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: 'America/New_York', isActive: true },
    ]
    const fill = async (user: ReturnType<typeof userEvent.setup>, dob: string) => {
      await user.type(await screen.findByLabelText('MRN'), 'NB-0001')
      await user.type(screen.getByLabelText('First name'), 'Baby')
      await user.type(screen.getByLabelText('Last name'), 'Synthetic')
      await user.type(screen.getByLabelText('Date of birth'), dob)
    }

    it('accepts a newborn born "today" at an IST branch although the workstation date is still yesterday', async () => {
      workstationAt('America/New_York')
      const calls = stubFetch({
        'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
        'GET /api/v1/branches': () => json(branches),
        'POST /api/v1/patients/duplicates': () => json({ candidates: [] }),
        'POST /api/v1/patients': (_u, init) => json({ id: 'p1', ...JSON.parse(String(init.body)) }, 201),
        'GET /api/v1/patients': () => json(listPage),
      })
      const user = userEvent.setup()
      renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
      await waitFor(() => expect(screen.getByLabelText('Date of birth')).toHaveAttribute('max', '2026-10-07'))
      await fill(user, '2026-10-07')
      await user.click(screen.getByRole('button', { name: /register patient/i }))

      expect(await screen.findByText(/patient NB-0001 registered/i)).toBeInTheDocument()
      expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({ dateOfBirth: '2026-10-07', registeredBranchId: ALPHA_MAIN })
    })

    it('rejects the same date for a branch whose day has not started yet, even if the workstation\'s has', async () => {
      workstationAt('Asia/Kolkata')
      const calls = stubFetch({
        'GET /api/v1/me': () => json(meFor({ activeBranchId: ALPHA_MAIN })),
        'GET /api/v1/branches': () => json(branches),
      })
      const user = userEvent.setup()
      renderWithProviders(<App />, { path: '/patients/new', auth: fakeAuthClient({ session: fakeSession() }) })
      await fill(user, '2026-10-07')
      await user.selectOptions(screen.getByLabelText('Registered branch'), ALPHA_EAST)
      await waitFor(() => expect(screen.getByLabelText('Date of birth')).toHaveAttribute('max', '2026-10-06'))
      await user.click(screen.getByRole('button', { name: /register patient/i }))

      expect(await screen.findByText('Date of birth must be between 1900-01-01 and today')).toBeInTheDocument()
      expect(calls.some((c) => c.method === 'POST')).toBe(false)
    })
  })
})
