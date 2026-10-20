import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

import { restoreWorkstation, workstationAt } from '../../test/timeZones'

afterEach(() => {
  restoreWorkstation()
  vi.unstubAllGlobals()
})

const PID = 'aa000000-0000-4000-8000-000000000001'
const detail = {
  id: PID,
  mrn: 'ALP-0001',
  firstName: 'Asha',
  lastName: 'Synthetic-Alpha',
  dateOfBirth: '1990-01-01',
  sex: 'female',
  registeredBranchId: ALPHA_MAIN,
  phone: '+91 98450 00001',
  email: null,
  deletedAt: null,
}
const emptyPage = { items: [], page: 1, pageSize: 25, totalCount: 0 }

describe('PatientDetailPage', () => {
  it('shows demographics; a receptionist can edit (and delete)', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'])),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`PATCH /api/v1/patients/${PID}`]: (_u, init) => json({ ...detail, ...JSON.parse(String(init.body)) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })

    const details = await screen.findByTestId('patient-details')
    expect(within(details).getByText('+91 98450 00001')).toBeInTheDocument()
    expect(within(details).getByText('Alpha Main')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Delete patient' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Edit patient' }))
    const form = screen.getByRole('form', { name: 'Edit patient' })
    expect(within(form).queryByLabelText('MRN')).not.toBeInTheDocument() // MRN is immutable: read-only text
    expect(within(form).getByTestId('edit-mrn')).toHaveTextContent('ALP-0001')
    await user.clear(within(form).getByLabelText('Phone (optional)'))
    await user.selectOptions(within(form).getByLabelText('Registered branch'), ALPHA_EAST)
    await user.click(within(form).getByRole('button', { name: 'Save changes' }))

    expect(await screen.findByText('Changes saved.')).toBeInTheDocument()
    const patch = calls.find((c) => c.method === 'PATCH')!
    expect(patch.body).toEqual({
      firstName: 'Asha',
      lastName: 'Synthetic-Alpha',
      dateOfBirth: '1990-01-01',
      sex: 'female',
      registeredBranchId: ALPHA_EAST,
      phone: null,
      email: null,
      whatsapp: null,
    })
    expect(patch.body).not.toHaveProperty('mrn')
    expect(within(screen.getByTestId('patient-details')).getByText('Alpha East')).toBeInTheDocument()
  })

  it('shows a WhatsApp badge when the phone is the WhatsApp number, else a WhatsApp line', async () => {
    const same = { ...detail, phone: '+919845000001', whatsappSameAsPhone: true, phones: [{ number: '+919845000001', isPrimary: true, isWhatsapp: true }] }
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'])),
      [`GET /api/v1/patients/${PID}`]: () => json(same),
    })
    const { unmount } = renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('whatsapp-same-badge')).toHaveTextContent('WhatsApp')
    expect(screen.queryByTestId('patient-whatsapp')).not.toBeInTheDocument()
    unmount()
    vi.unstubAllGlobals()

    const other = {
      ...detail,
      phone: '+919845000001',
      whatsappSameAsPhone: false,
      phones: [
        { number: '+919845000001', isPrimary: true, isWhatsapp: false },
        { number: '+971501234567', isPrimary: false, isWhatsapp: true },
      ],
    }
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'])),
      [`GET /api/v1/patients/${PID}`]: () => json(other),
      [`PATCH /api/v1/patients/${PID}`]: (_u, init) => json({ ...other, ...JSON.parse(String(init.body)) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-whatsapp')).toHaveTextContent('+971501234567')
    expect(screen.queryByTestId('whatsapp-same-badge')).not.toBeInTheDocument()

    // edit: the separate number is pre-filled with "Same as phone number" unticked; ticking sends sameAsPhone
    await user.click(screen.getByRole('button', { name: 'Edit patient' }))
    const form = screen.getByRole('form', { name: 'Edit patient' })
    const box = within(form).getByRole('checkbox', { name: 'Same as phone number' })
    expect(box).not.toBeChecked()
    expect(within(form).getByLabelText('WhatsApp number')).toHaveValue('+971501234567')
    await user.click(box)
    await user.click(within(form).getByRole('button', { name: 'Save changes' }))
    await screen.findByText('Changes saved.')
    expect(calls.find((c) => c.method === 'PATCH')!.body).toMatchObject({ whatsapp: { sameAsPhone: true } })
  })

  it('maps server validation errors onto the edit form', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`PATCH /api/v1/patients/${PID}`]: () => json({ title: 'Validation', status: 400, errors: { lastName: ['Too long'] } }, 400),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Edit patient' }))
    await user.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText('Too long')).toBeInTheDocument()
    expect(screen.getByText('Please fix the highlighted fields.')).toBeInTheDocument()
  })

  it('a receptionist at another branch cannot edit or delete', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_EAST)),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
    })
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-details')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Edit patient' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Delete patient' })).not.toBeInTheDocument()
  })

  it('maps a 409 invalid_state on delete to "cancel open appointments first"', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_MAIN)),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`DELETE /api/v1/patients/${PID}`]: () => json({ title: 'Conflict', status: 409, code: 'invalid_state' }, 409),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Delete patient' }))
    await user.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Delete patient' }))
    expect(await screen.findByText(/open appointments or is in today’s queue/)).toBeInTheDocument()
    // The Tailux modal fades out (Headless UI Transition) before it unmounts.
    await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
  })

  it('soft-deletes after confirmation (cancel first does nothing), sends the reason and returns to the list', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'], ALPHA_MAIN)),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`DELETE /api/v1/patients/${PID}`]: () => json(undefined, 204),
      'GET /api/v1/patients': () => json(emptyPage),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })

    await user.click(await screen.findByRole('button', { name: 'Delete patient' }))
    let dialog = screen.getByRole('alertdialog', { name: 'Delete this patient?' })
    expect(within(dialog).getByRole('button', { name: 'Cancel' })).toHaveFocus()
    await user.keyboard('{Escape}')
    // The Tailux modal fades out (Headless UI Transition) before it unmounts.
    await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
    expect(calls.some((c) => c.method === 'DELETE')).toBe(false)

    await user.click(screen.getByRole('button', { name: 'Delete patient' }))
    dialog = screen.getByRole('alertdialog')
    await user.type(within(dialog).getByLabelText('Reason (optional)'), 'Duplicate registration')
    await user.click(within(dialog).getByRole('button', { name: 'Delete patient' }))

    expect(await screen.findByText('Patient ALP-0001 deleted.')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Patients' })).toBeInTheDocument()
    const deletes = calls.filter((c) => c.method === 'DELETE')
    expect(deletes).toHaveLength(1)
    expect(deletes[0]!.body).toEqual({ reason: 'Duplicate registration' })
  })

  it('treats a 404 as deleted/not found, and flags a record returned with deletedAt as read-only', async () => {
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      [`GET /api/v1/patients/${PID}`]: () => json({ title: 'Not found', status: 404 }, 404),
      'GET /api/v1/patients/p-deleted': () => json({ ...detail, id: 'p-deleted', deletedAt: '2026-10-09T05:00:00Z' }),
    })
    const { unmount } = renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-not-found')).toHaveTextContent(/has been deleted/)
    unmount()

    renderWithProviders(<App />, { path: '/patients/p-deleted', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('patient-deleted-flag')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Edit patient' })).not.toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Delete patient' })).not.toBeInTheDocument()
  })

  it('edit form checks DOB against the patient\'s branch zone, not the workstation zone', async () => {
    workstationAt('America/New_York') // 2026-10-06 here, already 2026-10-07 at Alpha Main (IST)
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['receptionist'])),
      'GET /api/v1/branches': () =>
        json([
          { id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true },
          { id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: 'America/New_York', isActive: true },
        ]),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`PATCH /api/v1/patients/${PID}`]: (_u, init) => json({ ...detail, ...JSON.parse(String(init.body)) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })
    await user.click(await screen.findByRole('button', { name: 'Edit patient' }))
    const form = screen.getByRole('form', { name: 'Edit patient' })
    const dob = within(form).getByLabelText('Date of birth')
    await waitFor(() => expect(dob).toHaveAttribute('max', '2026-10-07'))
    await user.clear(dob)
    await user.type(dob, '2026-10-07')

    // Moving the patient to the New York branch makes 2026-10-07 a future date there
    await user.selectOptions(within(form).getByLabelText('Registered branch'), ALPHA_EAST)
    await waitFor(() => expect(dob).toHaveAttribute('max', '2026-10-06'))
    await user.click(within(form).getByRole('button', { name: 'Save changes' }))
    expect(await within(form).findByText('Date of birth must be between 1900-01-01 and today')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'PATCH')).toBe(false)

    await user.selectOptions(within(form).getByLabelText('Registered branch'), ALPHA_MAIN)
    await user.click(within(form).getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText('Changes saved.')).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'PATCH')!.body).toMatchObject({ dateOfBirth: '2026-10-07', registeredBranchId: ALPHA_MAIN })
  })
})
