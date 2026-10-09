import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

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
  it('shows demographics; a nurse can edit but not delete', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['nurse'])),
      [`GET /api/v1/patients/${PID}`]: () => json(detail),
      [`PATCH /api/v1/patients/${PID}`]: (_u, init) => json({ ...detail, ...JSON.parse(String(init.body)) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/patients/${PID}`, auth: fakeAuthClient({ session: fakeSession() }) })

    const details = await screen.findByTestId('patient-details')
    expect(within(details).getByText('+91 98450 00001')).toBeInTheDocument()
    expect(within(details).getByText('Alpha Main')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Delete patient' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Edit patient' }))
    const form = screen.getByRole('form', { name: 'Edit patient' })
    expect(within(form).queryByLabelText('MRN')).not.toBeInTheDocument() // MRN is immutable
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
    })
    expect(patch.body).not.toHaveProperty('mrn')
    expect(within(screen.getByTestId('patient-details')).getByText('Alpha East')).toBeInTheDocument()
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
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
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
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
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
})
