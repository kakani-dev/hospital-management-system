import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, appointment, branchesResponse, paged, practitionersApi, schedules } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

function routes(extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': (url) => json(schedules.filter((s) => s.branchId === url.searchParams.get('branchId'))),
    'GET /api/v1/appointments': () => json(paged([appointment({ status: 'completed' })])),
    ...extra,
  })
}

describe('Book follow-up', () => {
  it('a completed appointment offers "Book follow-up" that pre-fills patient and practitioner', async () => {
    routes()
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })
    const item = await screen.findByTestId('appointment')
    await user.click(await within(item).findByRole('button', { name: 'Book follow-up' }))
    const form = await screen.findByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(form).getByLabelText('Practitioner')).toHaveValue(DR_RAO))
    expect(form).toHaveTextContent('Synthetic-Alpha, Asha')
    expect(screen.getByRole('heading', { name: 'Book follow-up' })).toBeInTheDocument()
    // linked to the earlier visit (parentAppointmentId is sent with the booking)
    expect(within(form).getByTestId('follow-up-link')).toBeInTheDocument()
  })

  it('a doctor sees "Book follow-up" for another clinician\'s visit and not a fresh booking', async () => {
    routes({ 'GET /api/v1/me': () => json(meWithRoles(['doctor'], ALPHA_MAIN)) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })
    const item = await screen.findByTestId('appointment')
    await waitFor(() => expect(item).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(screen.queryByRole('button', { name: 'Book appointment' })).not.toBeInTheDocument()
    await user.click(within(item).getByRole('button', { name: 'Book follow-up' }))
    expect(await screen.findByTestId('follow-up-link')).toBeInTheDocument()
  })

  it('a booked appointment does not offer a follow-up', async () => {
    routes({ 'GET /api/v1/appointments': () => json(paged([appointment()])) })
    renderWithProviders(<App />, { path: `/appointments?branch=${ALPHA_MAIN}`, auth: fakeAuthClient({ session: fakeSession() }) })
    const item = await screen.findByTestId('appointment')
    await waitFor(() => expect(item).toHaveTextContent('Synthetic-Alpha, Asha'))
    expect(within(item).queryByRole('button', { name: 'Book follow-up' })).not.toBeInTheDocument()
  })

})
