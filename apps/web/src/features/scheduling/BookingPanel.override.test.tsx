import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, practitioners, today } from '../../test/schedulingFixtures'
import { BookingPanel } from './BookingPanel'

afterEach(() => vi.unstubAllGlobals())

describe('Booking outside working hours', () => {
  it('requires a reason once the override is ticked', async () => {
    stubFetch({
      'GET /api/v1/tenants/current': () => json({ id: 't', name: 'Synthetic', timeZone: 'Asia/Kolkata', defaultCountryCode: 'IN' }),
      'GET /api/v1/slots': () => json([]),
      'GET /api/v1/schedules': () => json([]),
    })
    const user = userEvent.setup()
    renderWithProviders(
      <BookingPanel
        branchId={ALPHA_MAIN}
        timeZone="Asia/Kolkata"
        initialDate={today()}
        minDate={today()}
        practitioners={practitioners.filter((p) => p.id === DR_RAO)}
        canOverrideHours
        onCancel={() => undefined}
        onBooked={() => undefined}
      />,
      { auth: fakeAuthClient({ session: fakeSession() }) },
    )
    const form = await screen.findByRole('form', { name: 'Book appointment' })
    expect(form).toHaveTextContent('Reason (optional)')
    await user.click(screen.getByRole('checkbox', { name: /Book outside working hours/ }))
    expect(screen.getByLabelText('Reason for booking outside working hours')).toBeRequired()
    expect(screen.getByTestId('booking-missing')).toHaveTextContent('a reason for booking outside working hours')
    expect(screen.getByRole('button', { name: 'Confirm booking' })).toBeDisabled()
  })
})
