import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, within } from '@testing-library/react'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse, DR_RAO, PATIENT_ID } from '../../test/schedulingFixtures'

afterEach(() => vi.unstubAllGlobals())

const open = () => renderWithProviders(<App />, { path: '/my-day', auth: fakeAuthClient({ session: fakeSession() }) })

describe('My day', () => {
  it('labels every branch on one timeline', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor({ timeZone: 'Asia/Kolkata' })),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/practitioners/me/day': () =>
        json({
          practitionerId: DR_RAO,
          displayName: 'Dr. Rao',
          date: '2030-06-03',
          items: [
            {
              kind: 'hours',
              branchId: ALPHA_MAIN,
              startsAt: '2030-06-03T03:30:00.000Z',
              endsAt: '2030-06-03T07:30:00.000Z',
              appointmentId: null,
              status: null,
              patient: null,
            },
            {
              kind: 'appointment',
              branchId: ALPHA_EAST,
              startsAt: '2030-06-03T11:30:00.000Z',
              endsAt: '2030-06-03T11:45:00.000Z',
              appointmentId: 'a1',
              status: 'booked',
              patient: { id: PATIENT_ID, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha' },
            },
          ],
        }),
    })
    open()
    const list = await screen.findByTestId('my-day')
    const items = await within(list).findAllByTestId('my-day-item')
    expect(items).toHaveLength(2)
    expect(items[0]).toHaveAttribute('data-kind', 'hours')
    expect(items[0]).toHaveTextContent('Alpha Main')
    expect(items[0]).toHaveTextContent('Working 09:00–13:00')
    expect(items[1]).toHaveAttribute('data-kind', 'appointment')
    expect(items[1]).toHaveTextContent('Alpha East')
    expect(items[1]).toHaveTextContent('Synthetic-Alpha, Asha')
  })

  it('says when the login is not linked to a practitioner', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/branches': () => json(branchesResponse),
      'GET /api/v1/practitioners/me/day': () => json({ practitionerId: null, displayName: null, date: '2030-06-03', items: [] }),
    })
    open()
    expect(await screen.findByText('Your login is not linked to a practitioner.')).toBeInTheDocument()
  })
})