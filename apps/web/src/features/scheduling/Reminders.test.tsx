import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'
import { ReminderPanel } from './ReminderPanel'
import { ReminderSettingsCard } from '../admin/ReminderSettingsCard'

afterEach(() => vi.unstubAllGlobals())

const APPT = 'e1111111-0000-4000-8000-0000000000aa'
const PATIENT = 'aa000000-0000-4000-8000-0000000000aa'
const tomorrow = new Date(Date.now() + 24 * 3600_000).toISOString()
const settings = {
  enabled: false, leadHours: 24, sameDayHours: 2, minNoticeMinutes: 120, emailEnabled: true, whatsappEnabled: false,
  quietStart: '21:00', quietEnd: '08:00', deliveryMode: 'TestRecipientsOnly', emailAvailable: true, whatsappAvailable: false,
}
const auth = () => fakeAuthClient({ session: fakeSession() })

describe('Appointment reminders (#59)', () => {
  it('shows reminder history inline and opts the patient out in one click', async () => {
    let optedOut = false
    const calls = stubFetch({
      [`GET /api/v1/reminders/appointments/${APPT}`]: () =>
        json({
          appointmentId: APPT, patientId: PATIENT, optedOut, optOutReason: null,
          reminders: [
            { id: 'r1', kind: 'lead', channel: 'email', status: 'skipped', detail: 'not a test recipient (reminders are in test mode)', recipientMasked: 'zz***@example.test', attempts: 1, scheduledStart: tomorrow, sentAt: null, createdOn: new Date().toISOString() },
          ],
        }),
      [`PUT /api/v1/reminders/opt-outs/${PATIENT}`]: () => {
        optedOut = true
        return new Response(null, { status: 204 })
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<ReminderPanel appointmentId={APPT} canEdit />, { auth: auth() })
    await user.click(screen.getByTestId('reminder-toggle'))
    const row = await screen.findByTestId('reminder-row')
    expect(row.dataset.status).toBe('skipped')
    expect(row).toHaveTextContent('zz***@example.test')
    await user.click(screen.getByTestId('reminder-opt-out'))
    await waitFor(() => expect(calls.some((c) => c.method === 'PUT' && c.path.endsWith(PATIENT))).toBe(true))
    await waitFor(() => expect(screen.getByTestId('reminder-opt-out')).toBeChecked())
  })

  it('disables the opt-out for staff who cannot book', async () => {
    stubFetch({ [`GET /api/v1/reminders/appointments/${APPT}`]: () => json({ appointmentId: APPT, patientId: PATIENT, optedOut: false, reminders: [] }) })
    const user = userEvent.setup()
    renderWithProviders(<ReminderPanel appointmentId={APPT} canEdit={false} />, { auth: auth() })
    await user.click(screen.getByTestId('reminder-toggle'))
    expect(await screen.findByTestId('reminder-empty')).toBeInTheDocument()
    expect(screen.getByTestId('reminder-opt-out')).toBeDisabled()
  })

  it('saves settings inline, blocks a same-day nudge longer than the lead, and explains test mode', async () => {
    const calls = stubFetch({
      'GET /api/v1/reminders/settings': () => json(settings),
      'PUT /api/v1/reminders/settings': (_u, init) => json({ ...settings, ...JSON.parse(String(init.body)) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<ReminderSettingsCard />, { auth: auth() })
    expect(await screen.findByTestId('reminder-mode')).toHaveTextContent('only to configured test recipients')
    expect(screen.getByTestId('reminder-whatsapp-enabled')).toBeDisabled()
    await user.clear(screen.getByTestId('reminder-same-day-hours'))
    await user.type(screen.getByTestId('reminder-same-day-hours'), '30')
    await user.clear(screen.getByTestId('reminder-lead-hours'))
    await user.type(screen.getByTestId('reminder-lead-hours'), '12')
    await user.click(screen.getByTestId('reminder-save'))
    expect(await screen.findByText('Same-day nudge must be less than the lead time.')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'PUT')).toBe(false)
    await user.clear(screen.getByTestId('reminder-same-day-hours'))
    await user.type(screen.getByTestId('reminder-same-day-hours'), '3')
    await user.click(screen.getByTestId('reminder-enabled'))
    await user.click(screen.getByTestId('reminder-save'))
    expect(await screen.findByText('Reminder settings saved.')).toBeInTheDocument()
    const put = calls.find((c) => c.method === 'PUT')!
    expect(put.body).toMatchObject({ enabled: true, leadHours: 12, sameDayHours: 3 })
    expect(put.body).not.toHaveProperty('deliveryMode')
  })
})
