import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, appointment, at, branchesResponse, paged, patientDetail, practitionersApi, schedules, today } from '../../test/schedulingFixtures'
import { prefillFromTerm } from './registerReturn'
import { patientOptionLabel } from './patientLabel'

afterEach(() => vi.unstubAllGlobals())

const RAVI = { ...patientDetail, id: 'aa000000-0000-4000-8000-000000000002', mrn: 'ALP-0002', firstName: 'Ravi', phone: '+91 98450 00002' }
const page = (items: unknown[]) => json({ items, page: 1, pageSize: 25, totalCount: items.length })

function routes(roles: string[], extra: Parameters<typeof stubFetch>[0] = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': () => json(schedules),
    'GET /api/v1/appointments': () => json(paged([appointment()])),
    ...extra,
  })
}

const render = (path: string) => renderWithProviders(<App />, { path, auth: fakeAuthClient({ session: fakeSession() }) })

describe('PatientPicker combobox', () => {
  it('↓/↑ move through matches, Enter picks without submitting the form, Esc closes then clears', async () => {
    const calls = routes(['receptionist'], { 'POST /api/v1/patients/search': () => page([patientDetail, RAVI]) })
    const user = userEvent.setup()
    render('/reception/check-in')
    const form = await screen.findByRole('form', { name: 'Walk-in check-in' })
    const box = within(form).getByRole('combobox', { name: 'Find walk-in patient' })

    await user.type(box, 'Syn')
    await waitFor(() => expect(within(form).getAllByTestId('patient-option')).toHaveLength(2))
    expect(box).toHaveAttribute('aria-expanded', 'true')
    // DOB/age and a masked phone help tell same-named patients apart
    expect(within(form).getAllByTestId('patient-option')[1]).toHaveTextContent(/Synthetic-Alpha, Ravi · ALP-0002 · .*…0002/)
    await user.keyboard('{ArrowDown}{ArrowDown}{ArrowDown}{ArrowUp}{ArrowDown}')
    const active = within(within(form).getByRole('listbox', { name: 'Matching patients' })).getByRole('option', { selected: true })
    expect(active).toHaveTextContent('Ravi')
    expect(box).toHaveAttribute('aria-activedescendant', active.id)
    await user.keyboard('{Enter}')
    expect(within(form).getByTestId('picked-patient')).toHaveTextContent('Synthetic-Alpha, Ravi ALP-0002')
    expect(calls.filter((c) => c.path === '/api/v1/queue/walk-in')).toHaveLength(0)
    expect(box).toHaveValue('')

    await user.type(box, 'Sy')
    await waitFor(() => expect(box).toHaveAttribute('aria-expanded', 'true'))
    await user.keyboard('{Escape}')
    expect(box).toHaveAttribute('aria-expanded', 'false')
    expect(box).toHaveValue('Sy')
    await user.keyboard('{Escape}')
    expect(box).toHaveValue('')
  })

  it('Enter picks the only match without arrowing', async () => {
    routes(['receptionist'], { 'POST /api/v1/patients/search': () => page([patientDetail]) })
    const user = userEvent.setup()
    render('/reception/check-in')
    const box = await screen.findByRole('combobox', { name: 'Find walk-in patient' })
    await user.type(box, 'ALP-0001')
    await screen.findByRole('option', { name: /Asha/ })
    await user.keyboard('{Enter}')
    expect(screen.getByTestId('picked-patient')).toHaveTextContent('Synthetic-Alpha, Asha')
  })

  it('no match → Register new (pre-filled) → back on check-in with the new patient selected', async () => {
    const created = { ...patientDetail, id: 'aa000000-0000-4000-8000-000000000099', mrn: 'NEW-0099', firstName: 'Kiran', lastName: 'Synthetic-New' }
    const calls = routes(['receptionist'], {
      'POST /api/v1/patients/search': () => page([]),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [] }),
      'POST /api/v1/patients': () => json(created, 201),
      'POST /api/v1/queue/walk-in': () => json({ queueEntryId: 'q9', tokenNo: 12, queueDate: today(), entry: null }, 201),
    })
    const user = userEvent.setup()
    render('/reception/check-in')
    const box = await screen.findByRole('combobox', { name: 'Find walk-in patient' })
    await user.type(box, 'Synthetic-New, Kiran')
    const register = await screen.findByTestId('register-new-patient')
    expect(register).toHaveTextContent('No match: register new patient “Synthetic-New, Kiran”')
    await user.keyboard('{ArrowDown}{Enter}')

    // Register form: pre-filled from the term (never via the URL), MRN focused
    await screen.findByRole('form', { name: 'Register patient' })
    expect(window.location.search).not.toContain('Kiran')
    expect(screen.getByLabelText('First name')).toHaveValue('Kiran')
    expect(screen.getByLabelText('Last name')).toHaveValue('Synthetic-New')
    await waitFor(() => expect(screen.getByLabelText('MRN')).toHaveFocus())
    await user.keyboard('NEW-0099')
    await user.click(screen.getByRole('button', { name: /register patient/i }))

    // Back on check-in, patient chosen, "Issue walk-in token" focused: Enter issues it
    const picked = await screen.findByTestId('picked-patient')
    expect(picked).toHaveTextContent('Synthetic-New, Kiran NEW-0099')
    expect(screen.getByRole('heading', { name: 'Reception check-in' })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Issue walk-in token' })).toHaveFocus())
    await user.keyboard('{Enter}')
    expect(await screen.findByTestId('token-number')).toHaveTextContent('12')
    expect(calls.find((c) => c.path === '/api/v1/queue/walk-in')!.body).toMatchObject({ patientId: created.id })
  })

  it('Alt+N in the picker opens Register pre-filled with the term', async () => {
    routes(['receptionist'], { 'POST /api/v1/patients/search': () => page([]) })
    const user = userEvent.setup()
    render('/reception/check-in')
    const box = await screen.findByRole('combobox', { name: 'Find walk-in patient' })
    await user.type(box, 'alp-0777')
    await user.keyboard('{Alt>}n{/Alt}')
    await screen.findByRole('form', { name: 'Register patient' })
    expect(screen.getByLabelText('MRN')).toHaveValue('ALP-0777')
    await waitFor(() => expect(screen.getByLabelText('First name')).toHaveFocus())
  })

  it('booking: register-new returns to the open panel with practitioner, slot and the new patient', async () => {
    const d = today()
    const slot = { practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(d, '23:00'), endsAt: at(d, '23:15') }
    const created = { ...patientDetail, id: 'aa000000-0000-4000-8000-000000000098', mrn: 'NEW-0098', firstName: 'Lata', lastName: 'Synthetic-New' }
    const calls = routes(['tenant_admin'], {
      'GET /api/v1/slots': () => json([slot]),
      'POST /api/v1/patients/search': () => page([]),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [] }),
      'POST /api/v1/patients': () => json(created, 201),
      'POST /api/v1/appointments': (_u, init) => json(appointment({ id: 'new', ...JSON.parse(String(init.body)) }), 201),
    })
    const user = userEvent.setup()
    render('/appointments')
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    let form = screen.getByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(within(form).getByLabelText('Practitioner')).getAllByRole('option')).toHaveLength(2))
    await user.selectOptions(within(form).getByLabelText('Practitioner'), DR_RAO)
    await user.click(await within(form).findByRole('radio', { name: '23:00' }))
    await user.type(within(form).getByLabelText('Find patient'), 'Lata Synthetic-New')
    await user.click(await within(form).findByTestId('register-new-patient'))

    expect(await screen.findByLabelText('First name')).toHaveValue('Lata')
    await user.type(screen.getByLabelText('MRN'), 'NEW-0098')
    await user.click(screen.getByRole('button', { name: /register patient/i }))

    form = await screen.findByRole('form', { name: 'Book appointment' })
    expect(within(form).getByLabelText('Practitioner')).toHaveValue(DR_RAO)
    await waitFor(() => expect(within(form).getByRole('radio', { name: '23:00' })).toBeChecked())
    expect(within(form).getByTestId('picked-patient')).toHaveTextContent('Synthetic-New, Lata NEW-0098')
    await waitFor(() => expect(within(form).getByRole('button', { name: 'Confirm booking' })).toHaveFocus())
    await user.keyboard('{Enter}')
    expect(await screen.findByText(/Booked Lata Synthetic-New with Dr. Rao/)).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/appointments')!.body).toMatchObject({ patientId: created.id, startsAt: slot.startsAt })
  })
})

describe('picker helpers', () => {
  it('prefillFromTerm splits MRNs and names', () => {
    expect(prefillFromTerm(' alp-0009 ')).toEqual({ mrn: 'ALP-0009' })
    expect(prefillFromTerm('Synthetic, Asha Devi')).toEqual({ lastName: 'Synthetic', firstName: 'Asha Devi' })
    expect(prefillFromTerm('Asha Synthetic Alpha')).toEqual({ firstName: 'Asha', lastName: 'Synthetic Alpha' })
    expect(prefillFromTerm('Asha')).toEqual({ firstName: 'Asha', lastName: '' })
    expect(prefillFromTerm('  ')).toEqual({})
  })

  it('patientOptionLabel shows DOB with age and only the last 4 phone digits', () => {
    const label = patientOptionLabel({ ...patientDetail, dateOfBirth: '1990-10-10', phone: '+91 98450 01234', sex: 'female' as const }, '2026-10-09')
    expect(label).toContain('1990-10-10 (35 y)')
    expect(label).toContain('ph …1234')
    expect(label).not.toContain('98450')
  })
})
