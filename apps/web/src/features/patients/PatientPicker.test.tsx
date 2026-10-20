import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, appointment, at, branchesResponse, paged, patientDetail, practitionersApi, schedules, today } from '../../test/schedulingFixtures'
import { prefillFromTerm } from './registerReturn'
import { patientOptionLabel } from './patientLabel'
import { PatientPicker } from './PatientPicker'

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

    // Register form: pre-filled from the term (never via the URL); no MRN input (server-generated)
    await screen.findByRole('form', { name: 'Register patient' })
    expect(window.location.search).not.toContain('Kiran')
    expect(screen.getByLabelText('First name')).toHaveValue('Kiran')
    expect(screen.getByLabelText('Last name')).toHaveValue('Synthetic-New')
    expect(screen.queryByLabelText('MRN')).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByLabelText('Date of birth')).toHaveFocus())
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
    // an MRN-like term pre-fills nothing: MRNs are generated by the server
    expect(screen.queryByLabelText('MRN')).not.toBeInTheDocument()
    expect(screen.getByLabelText('First name')).toHaveValue('')
    await waitFor(() => expect(screen.getByLabelText('First name')).toHaveFocus())
  })

  async function openBooking(user: ReturnType<typeof userEvent.setup>) {
    render('/appointments')
    await user.click(await screen.findByRole('button', { name: 'Book appointment' }))
    const form = screen.getByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(form).getByLabelText('Practitioner').querySelectorAll('option')).toHaveLength(2))
    await user.selectOptions(within(form).getByLabelText('Practitioner'), DR_RAO)
    await user.click(await within(form).findByRole('radio', { name: '23:00' }))
    return form
  }
  const bookingRoutes = (roles: string[], extra: Parameters<typeof stubFetch>[0] = {}) => {
    const d = today()
    const slot = { practitionerId: DR_RAO, branchId: ALPHA_MAIN, startsAt: at(d, '23:00'), endsAt: at(d, '23:15') }
    const calls = routes(roles, {
      'GET /api/v1/slots': () => json([slot]),
      'GET /api/v1/patients': () => page([RAVI]),
      'POST /api/v1/patients/search': () => page([]),
      'POST /api/v1/patients/duplicates': () => json({ candidates: [] }),
      'POST /api/v1/appointments': (_u, init) => json(appointment({ id: 'new', ...JSON.parse(String(init.body)) }), 201),
      ...extra,
    })
    return { calls, slot }
  }
  const NEW = { ...patientDetail, id: 'aa000000-0000-4000-8000-000000000098', mrn: 'NEW-0098', firstName: 'Lata', lastName: 'Synthetic-New' }

  it('booking: "+ New patient" registers inline in the drawer, keeps the slot, selects the patient, Enter books', async () => {
    const { calls, slot } = bookingRoutes(['tenant_admin'], { 'POST /api/v1/patients': () => json(NEW, 201) })
    const user = userEvent.setup()
    const form = await openBooking(user)
    await user.type(within(form).getByLabelText('Find patient'), 'Lata Synthetic-New')
    const option = await within(form).findByTestId('register-new-patient')
    expect(option).toHaveTextContent('+ New patient “Lata Synthetic-New”')
    await user.click(option)

    const quick = within(form).getByTestId('quick-register')
    expect(within(quick).getByLabelText('First name')).toHaveValue('Lata')
    expect(within(quick).getByLabelText('Last name')).toHaveValue('Synthetic-New')
    expect(within(quick).getByLabelText('Same as phone number')).toBeChecked()
    expect(within(quick).queryByLabelText('Registered branch')).toBeNull()
    expect(screen.getByRole('form', { name: 'Book appointment' })).toBe(form) // same drawer, no navigation
    await user.click(within(quick).getByTestId('save-patient'))

    expect(await within(form).findByTestId('picked-patient')).toHaveTextContent('Synthetic-New, Lata NEW-0098')
    expect(within(form).getByRole('radio', { name: '23:00' })).toBeChecked()
    await waitFor(() => expect(within(form).getByRole('button', { name: 'Confirm booking' })).toHaveFocus())
    await user.keyboard('{Enter}')
    expect(await screen.findByText(/Booked Lata Synthetic-New with Dr. Rao/)).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({
      firstName: 'Lata', lastName: 'Synthetic-New', registeredBranchId: ALPHA_MAIN, sex: 'unknown',
    })
    expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/appointments')!.body).toMatchObject({ patientId: NEW.id, startsAt: slot.startsAt })
  })

  it('booking: a phone search pre-fills +91 phone, and "Save & book" registers and books in one action', async () => {
    const { calls } = bookingRoutes(['receptionist'], { 'POST /api/v1/patients': () => json(NEW, 201) })
    const user = userEvent.setup()
    const form = await openBooking(user)
    await user.type(within(form).getByLabelText('Find patient'), '98450 77777')
    await user.click(await within(form).findByTestId('register-new-patient'))
    const quick = within(form).getByTestId('quick-register')
    expect(within(quick).getByLabelText(/Phone/)).toHaveValue('+91 98450 77777')
    await waitFor(() => expect(within(quick).getByLabelText('First name')).toHaveFocus())
    await user.keyboard('Lata{Tab}Synthetic-New')
    await user.click(within(quick).getByTestId('save-and-book'))
    expect(await screen.findByText(/Booked Lata Synthetic-New with Dr. Rao/)).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST' && c.path === '/api/v1/patients')!.body).toMatchObject({
      phone: '+91 98450 77777', whatsapp: { sameAsPhone: true },
    })
    expect(calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/appointments')).toHaveLength(1)
  })

  it('booking: possible duplicates offer "Use existing", which selects that patient without creating one', async () => {
    const dup = { id: RAVI.id, mrn: RAVI.mrn, firstName: RAVI.firstName, lastName: RAVI.lastName, dateOfBirth: null, phone: RAVI.phone, registeredBranchId: ALPHA_MAIN, matchReasons: ['phone'] }
    const { calls } = bookingRoutes(['receptionist'], {
      'POST /api/v1/patients/duplicates': () => json({ candidates: [dup] }),
      [`GET /api/v1/patients/${RAVI.id}`]: () => json(RAVI),
      'POST /api/v1/patients': () => json(NEW, 201),
    })
    const user = userEvent.setup()
    const form = await openBooking(user)
    await user.type(within(form).getByLabelText('Find patient'), 'Ravi Synthetic-Alpha')
    await user.click(await within(form).findByTestId('register-new-patient'))
    const quick = within(form).getByTestId('quick-register')
    await user.type(within(quick).getByLabelText(/Phone/), '+91 98450 00002')
    await user.click(within(quick).getByTestId('save-and-book'))
    await user.click(await within(form).findByTestId('use-existing'))
    expect(await within(form).findByTestId('picked-patient')).toHaveTextContent('Synthetic-Alpha, Ravi ALP-0002')
    expect(calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/patients')).toHaveLength(0)
    expect(calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/appointments')).toHaveLength(0)
  })

  it('booking: focus shows recent patients at once; "+ New patient" stays the last option even with matches', async () => {
    bookingRoutes(['receptionist'], { 'POST /api/v1/patients/search': () => page([RAVI]) })
    const user = userEvent.setup()
    const form = await openBooking(user)
    await user.click(within(form).getByLabelText('Find patient'))
    expect(await within(form).findByRole('listbox', { name: 'Recent patients' })).toBeInTheDocument()
    expect(within(form).getAllByTestId('patient-option')[0]).toHaveTextContent('Ravi')
    await user.type(within(form).getByLabelText('Find patient'), 'Ra')
    await waitFor(() => expect(within(form).getByRole('listbox', { name: 'Matching patients' })).toBeInTheDocument())
    const options = within(within(form).getByRole('listbox', { name: 'Matching patients' })).getAllByRole('option')
    expect(options.at(-1)).toHaveAttribute('data-testid', 'register-new-patient')
  })

  it('users without patients.create get no "+ New patient" option (picker in inline mode)', async () => {
    routes(['nurse'], { 'POST /api/v1/patients/search': () => page([]) })
    const user = userEvent.setup()
    const onCreateNew = vi.fn()
    renderWithProviders(<PatientPicker value={null} onChange={() => {}} onCreateNew={onCreateNew} />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    const box = await screen.findByRole('combobox', { name: 'Find patient' })
    await waitFor(() => expect(screen.queryByText(/loading/i)).toBeNull())
    await user.type(box, 'Nobody Here')
    await screen.findByText('No matching patients.')
    expect(screen.queryByTestId('register-new-patient')).toBeNull()
  })
})

describe('picker helpers', () => {
  it('prefillFromTerm splits names; MRN-like terms pre-fill nothing', () => {
    expect(prefillFromTerm(' alp-0009 ')).toEqual({})
    expect(prefillFromTerm('Synthetic, Asha Devi')).toEqual({ lastName: 'Synthetic', firstName: 'Asha Devi' })
    expect(prefillFromTerm('Asha Synthetic Alpha')).toEqual({ firstName: 'Asha', lastName: 'Synthetic Alpha' })
    expect(prefillFromTerm('Asha')).toEqual({ firstName: 'Asha', lastName: '' })
    expect(prefillFromTerm('  ')).toEqual({})
    expect(prefillFromTerm('98450 77777')).toEqual({ phone: '+91 98450 77777' })
    expect(prefillFromTerm('+971 50 123 4567')).toEqual({ phone: '+971 50 123 4567' })
  })

  it('patientOptionLabel shows DOB with age and only the last 4 phone digits', () => {
    const label = patientOptionLabel({ ...patientDetail, dateOfBirth: '1990-10-10', phone: '+91 98450 01234', sex: 'female' as const }, '2026-10-09')
    expect(label).toContain('1990-10-10 (35 y)')
    expect(label).toContain('ph …1234')
    expect(label).not.toContain('98450')
  })
})

describe('PatientPicker exact-MRN first', () => {
  const RAVI_10 = { ...RAVI, id: 'aa000000-0000-4000-8000-000000000010', mrn: 'ALP-00020', firstName: 'Anil' }

  it('puts the exact MRN match at the top and Enter picks it even with several matches', async () => {
    // Server order is by name: the exact match (ALP-0002, Ravi) comes last.
    const calls = routes(['receptionist'], { 'POST /api/v1/patients/search': () => page([RAVI_10, patientDetail, RAVI]) })
    const user = userEvent.setup()
    render('/reception/check-in')
    const form = await screen.findByRole('form', { name: 'Walk-in check-in' })
    const box = within(form).getByRole('combobox', { name: 'Find walk-in patient' })

    await user.type(box, 'alp-0002')
    await waitFor(() => expect(within(form).getAllByTestId('patient-option')).toHaveLength(3))
    const options = within(form).getAllByTestId('patient-option')
    expect(options[0]).toHaveTextContent('Synthetic-Alpha, Ravi · ALP-0002 ')
    expect(within(options[0]!).getByTestId('exact-mrn-badge')).toHaveTextContent('Exact MRN')
    expect(within(form).getAllByTestId('exact-mrn-badge')).toHaveLength(1)
    await user.keyboard('{Enter}')
    expect(within(form).getByTestId('picked-patient')).toHaveTextContent('Synthetic-Alpha, Ravi ALP-0002')
    // Still one POST search with the term in the body (2-character minimum and debounce unchanged).
    expect(calls.filter((c) => c.path === '/api/v1/patients/search')).toHaveLength(1)
  })

  it('without an exact MRN match, Enter with several matches still waits for a choice', async () => {
    routes(['receptionist'], { 'POST /api/v1/patients/search': () => page([RAVI_10, patientDetail, RAVI]) })
    const user = userEvent.setup()
    render('/reception/check-in')
    const form = await screen.findByRole('form', { name: 'Walk-in check-in' })
    const box = within(form).getByRole('combobox', { name: 'Find walk-in patient' })
    await user.type(box, 'ALP-000')
    await waitFor(() => expect(within(form).getAllByTestId('patient-option')).toHaveLength(3))
    expect(within(form).queryByTestId('exact-mrn-badge')).not.toBeInTheDocument()
    await user.keyboard('{Enter}')
    expect(within(form).queryByTestId('picked-patient')).not.toBeInTheDocument()
    expect(box).toHaveValue('ALP-000')
  })
})
