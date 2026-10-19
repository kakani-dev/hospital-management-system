import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, renderHook, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { PATIENT_SEARCH_DEBOUNCE_MS } from '../../lib/api/hooks'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

const patient = {
  id: 'p1',
  mrn: 'ALP-0001',
  firstName: 'Asha',
  lastName: 'Synthetic-Alpha',
  dateOfBirth: '1990-01-01',
  sex: 'female',
  registeredBranchId: ALPHA_MAIN,
}

describe('patient search', () => {
  it('debounces typing into a single POST /patients/search with the term in the body, never in the URL', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
      'POST /api/v1/patients/search': () => json({ items: [patient], page: 1, pageSize: 25, totalCount: 1 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patients-empty')).toBeInTheDocument()

    await user.type(screen.getByLabelText('Search patients'), 'Synthetic')
    expect(await screen.findByTestId('patient-row')).toHaveTextContent('ALP-0001')

    const searches = calls.filter((c) => c.path === '/api/v1/patients/search')
    expect(searches).toHaveLength(1) // not one per keystroke
    expect(searches[0]).toMatchObject({ method: 'POST', body: { search: 'Synthetic', pageSize: 25 } })
    expect(calls.every((c) => !c.url.includes('search=') && !c.url.includes('Synthetic'))).toBe(true)
    expect(calls.filter((c) => c.path === '/api/v1/patients').every((c) => c.method === 'GET')).toBe(true)
  })

  it('goes back to the paged GET list when the search box is cleared', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [patient], page: 1, pageSize: 25, totalCount: 1 }),
      'POST /api/v1/patients/search': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-row')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Search patients'), 'zz')
    expect(await screen.findByTestId('patients-empty')).toBeInTheDocument()
    await user.clear(screen.getByLabelText('Search patients'))
    expect(await screen.findByTestId('patient-row')).toBeInTheDocument()
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/patients/search')).toHaveLength(1))
    expect(calls.filter((c) => c.method === 'GET' && c.path === '/api/v1/patients').at(-1)!.url).toBe('/api/v1/patients?pageSize=25')
  })
})

describe('patient search length cap', () => {
  it('caps the search box at 100 characters and never posts a longer term', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
      'POST /api/v1/patients/search': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
    })
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    const input = await screen.findByLabelText('Search patients')
    expect(input).toHaveAttribute('maxLength', '100')
    await userEvent.setup().type(input, `  ${'a'.repeat(120)}`)
    await waitFor(() => expect(calls.some((c) => c.path === '/api/v1/patients/search')).toBe(true))
    const term = (calls.filter((c) => c.path === '/api/v1/patients/search').at(-1)!.body as { search: string }).search
    expect(term.length).toBeLessThanOrEqual(100)
    expect(term).toBe(term.trim())
  })
})

describe('useDebouncedValue', () => {
  it(`waits ${PATIENT_SEARCH_DEBOUNCE_MS} ms after the last change`, () => {
    expect(PATIENT_SEARCH_DEBOUNCE_MS).toBe(300)
    vi.useFakeTimers()
    const { result, rerender } = renderHook(({ value }) => useDebouncedValue(value, PATIENT_SEARCH_DEBOUNCE_MS), {
      initialProps: { value: '' },
    })
    rerender({ value: 'a' })
    act(() => void vi.advanceTimersByTime(200))
    rerender({ value: 'ab' })
    act(() => void vi.advanceTimersByTime(299))
    expect(result.current).toBe('')
    act(() => void vi.advanceTimersByTime(1))
    expect(result.current).toBe('ab')
  })
})

describe('patient search by phone and date of birth', () => {
  it('sends phone and DOB in the POST body (never the URL) and links rows to the detail page', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
      'POST /api/v1/patients/search': () => json({ items: [patient], page: 1, pageSize: 25, totalCount: 1 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('patients-empty')

    await user.type(screen.getByLabelText('Phone'), '98450')
    await user.type(screen.getByLabelText('Date of birth'), '1990-01-01')
    // Fewer than 7 digits is a 400 from the API: the phone is held back until it is long enough.
    await waitFor(() => expect(calls.filter((c) => c.path === '/api/v1/patients/search').at(-1)?.body).toEqual({ dateOfBirth: '1990-01-01', pageSize: 25 }))
    expect(screen.queryByLabelText('Include deleted patients')).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Phone'), '00001')
    const row = await screen.findByTestId('patient-row')
    expect(within(row).getByRole('link', { name: 'Synthetic-Alpha, Asha' })).toHaveAttribute('href', '/patients/p1')

    await waitFor(() => {
      const last = calls.filter((c) => c.path === '/api/v1/patients/search').at(-1)!
      expect(last.body).toEqual({ phone: '9845000001', dateOfBirth: '1990-01-01', pageSize: 25 })
    })
    expect(calls.every((c) => !c.url.includes('98450') && !c.url.includes('1990-01-01'))).toBe(true)
  })

  it('lets a tenant admin include deleted patients (flagged) and restore one', async () => {
    let deletedAt: string | null = '2026-10-09T05:00:00Z'
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['tenant_admin'])),
      'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
      'POST /api/v1/patients/search': () => json({ items: [{ ...patient, deletedAt }], page: 1, pageSize: 25, totalCount: 1 }),
      'POST /api/v1/patients/p1/restore': () => {
        deletedAt = null
        return json(undefined, 204)
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('patients-empty')
    await user.click(screen.getByLabelText('Include deleted patients'))

    expect(await screen.findByTestId('patient-deleted-badge')).toBeInTheDocument()
    expect(calls.find((c) => c.path === '/api/v1/patients/search')!.body).toEqual({ includeDeleted: true, pageSize: 25 })
    expect(within(screen.getByTestId('patient-row')).queryByRole('link')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Restore ALP-0001' }))
    await waitFor(() => expect(screen.queryByTestId('patient-deleted-badge')).not.toBeInTheDocument())
    expect(within(screen.getByTestId('patient-row')).getByText('Active')).toBeInTheDocument()
  })
})

describe('patient list paging (Tailux pagination, server-side)', () => {
  it('requests the next page from the API and starts again at page 1 when the search changes', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': (url) => {
        const page = Number(url.searchParams.get('page') ?? '1')
        return json({ items: [{ ...patient, id: `p${page}`, mrn: `ALP-P${page}` }], page, pageSize: 25, totalCount: 60 })
      },
      'POST /api/v1/patients/search': () => json({ items: [patient], page: 1, pageSize: 25, totalCount: 1 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-row')).toHaveTextContent('ALP-P1')
    expect(screen.getByText('1 - 25 of 60 entries')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Page 2' }))
    await waitFor(() => expect(screen.getByTestId('patient-row')).toHaveTextContent('ALP-P2'))
    expect(calls.filter((c) => c.method === 'GET' && c.path === '/api/v1/patients').at(-1)!.url).toBe('/api/v1/patients?page=2&pageSize=25')
    expect(screen.getByRole('button', { name: 'Page 2' })).toHaveAttribute('aria-current', 'page')

    await user.type(screen.getByLabelText('Search patients'), 'Synthetic')
    await waitFor(() => expect(screen.getByTestId('patients-total')).toHaveTextContent('1 patient'))
    const searches = calls.filter((c) => c.path === '/api/v1/patients/search')
    expect(searches).toHaveLength(1)
    expect(searches[0]!.body).toEqual({ search: 'Synthetic', pageSize: 25 })
    expect(screen.queryByRole('navigation', { name: 'Pagination' })).not.toBeInTheDocument()
  })
})

describe('patient list exact-MRN first', () => {
  it('shows the patient whose MRN exactly matches the search at the top', async () => {
    const others = [
      { ...patient, id: 'p10', mrn: 'ALP-00010', firstName: 'Anil', lastName: 'Synthetic-A' },
      { ...patient, id: 'p11', mrn: 'ALP-00011', firstName: 'Bina', lastName: 'Synthetic-B' },
    ]
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ roles: ['receptionist'] })),
      'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
      'POST /api/v1/patients/search': () => json({ items: [...others, patient], page: 1, pageSize: 25, totalCount: 3 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('patients-empty')
    await user.type(screen.getByLabelText('Search patients'), 'ALP-0001')
    await waitFor(() => expect(screen.getAllByTestId('patient-row')).toHaveLength(3))
    const rows = screen.getAllByTestId('patient-row')
    expect(rows[0]).toHaveTextContent('ALP-0001')
    expect(within(rows[0]!).getByTestId('exact-mrn-badge')).toBeInTheDocument()
    expect(rows.map((r) => within(r).getByTestId('patient-link').textContent)).toEqual([
      'Synthetic-Alpha, Asha',
      'Synthetic-A, Anil',
      'Synthetic-B, Bina',
    ])
  })
})
