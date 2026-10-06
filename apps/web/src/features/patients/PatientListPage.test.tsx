import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, renderHook, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { PATIENT_SEARCH_DEBOUNCE_MS } from '../../lib/api/hooks'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

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
