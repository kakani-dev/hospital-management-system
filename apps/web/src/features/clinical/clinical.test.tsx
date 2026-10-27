import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, PATIENT_ID, branchesResponse, patientRef, practitionersApi, today } from '../../test/schedulingFixtures'
import type { Consultation } from '../../lib/api/types'
import { validateLines } from './consultationModel'

afterEach(() => vi.unstubAllGlobals())

// Synthetic data only.
const CID = 'c0000000-0000-4000-8000-000000000001'
const CID2 = 'c0000000-0000-4000-8000-000000000002'
const auth = () => fakeAuthClient({ session: fakeSession() })

const consultation = (o: Partial<Consultation> = {}): Consultation => ({
  id: CID,
  branchId: ALPHA_MAIN,
  patientId: PATIENT_ID,
  practitionerId: DR_RAO,
  practitionerName: 'Dr. Rao (synthetic)',
  queueEntryId: 'q1',
  appointmentId: null,
  rootId: CID,
  version: 1,
  supersedesId: null,
  isLatest: true,
  status: 'draft',
  chiefComplaint: 'Fever (synthetic)',
  notes: 'Synthetic note',
  diagnosisText: 'Viral fever',
  diagnosisCode: 'B34.9',
  followUpDate: null,
  advice: null,
  finalizedOn: null,
  rowVersion: 3,
  createdOn: '2026-10-26T05:00:00Z',
  updatedOn: '2026-10-26T05:00:00Z',
  lines: [{ lineNo: 1, medicineName: 'Paracetamol', strength: '500 mg', dose: '1 tab', frequency: '1-0-1', durationDays: 3, route: 'oral', foodTiming: 'after_food', instructions: null }],
  ...o,
})
const finalized = (o: Partial<Consultation> = {}) => consultation({ status: 'finalized', finalizedOn: '2026-10-26T06:00:00Z', rowVersion: 5, ...o })
const problem = (status: number, detail: string) =>
  new Response(JSON.stringify({ title: 'x', status, detail }), { status, headers: { 'Content-Type': 'application/problem+json' } })

const base = (roles: string[]) => ({
  'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
  'GET /api/v1/branches': () => json(branchesResponse),
  'GET /api/v1/practitioners': practitionersApi,
})

const queueEntry = (status: string) => ({
  id: 'q1', branchId: ALPHA_MAIN, queueDate: today(), tokenNo: 7, patientId: PATIENT_ID, patient: patientRef,
  appointmentId: null, practitionerId: DR_RAO, status, checkedInAt: new Date().toISOString(),
})

describe('open a consultation from the queue', () => {
  it('a doctor opens the consultation of the token in consultation and lands on the editor', async () => {
    const calls = stubFetch({
      ...base(['doctor']),
      'GET /api/v1/queue': () => json([queueEntry('in_consultation')]),
      'POST /api/v1/consultations': () => json(consultation({ lines: [] }), 201),
      [`GET /api/v1/consultations/${CID}`]: () => json(consultation({ lines: [] })),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Open consultation for token 7' }))
    expect(await screen.findByRole('form', { name: 'Consultation' })).toBeInTheDocument()
    expect(calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/consultations').map((c) => c.body)).toEqual([{ queueEntryId: 'q1' }])
  })

  it('front desk and nurses never get the button (doctor-only write)', async () => {
    for (const role of ['receptionist', 'nurse']) {
      stubFetch({ ...base([role]), 'GET /api/v1/queue': () => json([queueEntry('in_consultation')]) })
      const { unmount } = renderWithProviders(<App />, { path: '/queue', auth: auth() })
      await screen.findAllByTestId('queue-entry')
      expect(screen.queryByRole('button', { name: /Open consultation/ })).not.toBeInTheDocument()
      unmount()
      vi.unstubAllGlobals()
    }
  })

  it('a patient who is not checked in (409) explains instead of navigating', async () => {
    stubFetch({
      ...base(['doctor']),
      'GET /api/v1/queue': () => json([queueEntry('in_consultation')]),
      'POST /api/v1/consultations': () => problem(409, 'the patient is not checked in'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Open consultation for token 7' }))
    expect(await screen.findByText('the patient is not checked in')).toBeInTheDocument()
    expect(screen.queryByRole('form', { name: 'Consultation' })).not.toBeInTheDocument()
  })
})

describe('consultation editor', () => {
  it('saves header and prescription lines with the row version', async () => {
    const calls = stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(consultation()),
      [`PUT /api/v1/consultations/${CID}`]: (_u, init) => json({ ...consultation(), ...JSON.parse(String(init.body)), rowVersion: 4 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    const form = await screen.findByRole('form', { name: 'Consultation' })
    expect(screen.getByTestId('consultation-status')).toHaveTextContent('Draft')
    await user.click(within(form).getByRole('button', { name: 'Add medicine' }))
    await user.type(within(form).getByLabelText('Medicine 2'), 'Cetirizine')
    const line2 = within(form).getByRole('listitem', { name: 'Line 2' })
    await user.type(within(line2).getByLabelText(/Frequency/), '0-0-1')
    await user.type(within(line2).getByLabelText('Duration (days)'), '5')
    await user.selectOptions(within(line2).getByLabelText('Food'), 'after_food')
    await user.type(within(form).getByLabelText('Follow-up date'), '2026-11-02')
    await user.click(within(form).getByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('Draft saved.')).toBeInTheDocument()
    const put = calls.find((c) => c.method === 'PUT')!.body as { rowVersion: number; lines: unknown[]; followUpDate: string }
    expect(put.rowVersion).toBe(3)
    expect(put.followUpDate).toBe('2026-11-02')
    expect(put.lines).toEqual([
      expect.objectContaining({ medicineName: 'Paracetamol', frequency: '1-0-1' }),
      { medicineName: 'Cetirizine', strength: null, dose: null, frequency: '0-0-1', durationDays: 5, route: null, foodTiming: 'after_food', instructions: null },
    ])
  })

  it('an invalid line is flagged in the form and never sent', async () => {
    const calls = stubFetch({ ...base(['doctor']), [`GET /api/v1/consultations/${CID}`]: () => json(consultation({ lines: [] })) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    const form = await screen.findByRole('form', { name: 'Consultation' })
    await user.click(within(form).getByRole('button', { name: 'Add medicine' }))
    await user.click(within(form).getByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('Medicine is required.')).toBeInTheDocument()
    expect(screen.getByText('Frequency is required.')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'PUT')).toBe(false)
    expect(validateLines([{ medicineName: 'X', frequency: 'OD', durationDays: 0, strength: null, dose: null, route: null, foodTiming: null, instructions: null }])).toEqual({
      'line-0-durationDays': 'Duration must be 1–365 days.',
    })
  })

  it('a server 400 for a line shows the server message', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(consultation()),
      [`PUT /api/v1/consultations/${CID}`]: () => problem(400, 'line 1: route is too long'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('Please fix: line 1: route is too long')).toBeInTheDocument()
  })

  it('a concurrent edit (409 stale row version) reloads the server copy instead of overwriting it', async () => {
    let reads = 0
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(++reads === 1 ? consultation() : consultation({ rowVersion: 4, chiefComplaint: 'Edited elsewhere' })),
      [`PUT /api/v1/consultations/${CID}`]: () => problem(409, 'the consultation was changed by someone else; reload it'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    const complaint = await screen.findByLabelText('Chief complaint')
    await user.clear(complaint)
    await user.type(complaint, 'Mine')
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('the consultation was changed by someone else; reload it')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByLabelText('Chief complaint')).toHaveValue('Edited elsewhere'))
  })

  it('a doctor who is not the treating doctor (403) is told so', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(consultation()),
      [`PUT /api/v1/consultations/${CID}`]: () => problem(403, 'forbidden'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('Only the treating doctor can change this consultation.')).toBeInTheDocument()
  })
})

describe('finalize and revise', () => {
  it('finalize saves, then finalizes once even on a double click, and the record becomes read-only', async () => {
    let finalizedNow = false
    const calls = stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(finalizedNow ? finalized() : consultation()),
      [`PUT /api/v1/consultations/${CID}`]: () => json(consultation({ rowVersion: 4 })),
      [`POST /api/v1/consultations/${CID}/finalize`]: async () => {
        await new Promise((r) => setTimeout(r, 30))
        finalizedNow = true
        return json(finalized())
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Finalize' }))
    const dialog = await screen.findByRole('alertdialog')
    const confirm = within(dialog).getByRole('button', { name: 'Finalize' })
    await user.dblClick(confirm)
    await waitFor(() => expect(screen.getByTestId('consultation-status')).toHaveTextContent('Finalized'))
    expect(calls.filter((c) => c.path.endsWith('/finalize')).map((c) => c.body)).toEqual([{ rowVersion: 4 }])
    expect(calls.filter((c) => c.method === 'PUT')).toHaveLength(1)
    // edit after finalize: no inputs, no save
    expect(screen.queryByRole('form', { name: 'Consultation' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Chief complaint')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Print prescription' })).toHaveAttribute('href', `/consultations/${CID}/print`)
  })

  it('finalize refused for a missing registration number shows the reason and keeps the draft (#128)', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(consultation()),
      [`PUT /api/v1/consultations/${CID}`]: () => json(consultation({ rowVersion: 4 })),
      [`POST /api/v1/consultations/${CID}/finalize`]: () =>
        problem(400, 'add your council registration number (Administration > Practitioners) before finalizing; it must be printed on the prescription'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Finalize' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Finalize' }))
    expect(await screen.findByText(/add your council registration number/)).toBeInTheDocument()
    expect(screen.getByTestId('consultation-status')).toHaveTextContent('Draft')
  })

  it('revise creates a new draft version and opens it', async () => {
    const calls = stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}`]: () => json(finalized()),
      [`POST /api/v1/consultations/${CID}/revisions`]: () => json(consultation({ id: CID2, version: 2, supersedesId: CID, rowVersion: 1 }), 201),
      [`GET /api/v1/consultations/${CID2}`]: () => json(consultation({ id: CID2, version: 2, supersedesId: CID, rowVersion: 1 })),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Revise (new version)' }))
    expect(await screen.findByRole('form', { name: 'Consultation' })).toBeInTheDocument()
    expect(screen.getByText(/v2/)).toBeInTheDocument()
    expect(calls.filter((c) => c.path.endsWith('/revisions'))).toHaveLength(1)
  })

  it('a superseded version has no Revise button and says a newer version exists', async () => {
    stubFetch({ ...base(['doctor']), [`GET /api/v1/consultations/${CID}`]: () => json(finalized({ isLatest: false })) })
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    expect(await screen.findByText('A newer version of this prescription exists.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Revise/ })).not.toBeInTheDocument()
  })

  it('a nurse sees a draft read-only, without print', async () => {
    stubFetch({ ...base(['nurse']), [`GET /api/v1/consultations/${CID}`]: () => json(consultation()) })
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    expect(await screen.findByTestId('consultation-summary')).toHaveTextContent('Paracetamol 500 mg')
    expect(screen.queryByRole('form', { name: 'Consultation' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Print prescription' })).not.toBeInTheDocument()
  })

  it('another tenant or branch (404) shows unavailable, with no data', async () => {
    stubFetch({ ...base(['doctor']), [`GET /api/v1/consultations/${CID}`]: () => problem(404, 'not found') })
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    expect(await screen.findByTestId('consultation-unavailable')).toHaveTextContent('does not exist in this hospital or branch')
  })

  it('billing cannot open the consultation route at all', async () => {
    const calls = stubFetch({ ...base(['billing']) })
    renderWithProviders(<App />, { path: `/consultations/${CID}`, auth: auth() })
    await waitFor(() => expect(calls.some((c) => c.path === '/api/v1/me')).toBe(true))
    await new Promise((r) => setTimeout(r, 50))
    expect(calls.some((c) => c.path.startsWith('/api/v1/consultations'))).toBe(false)
    expect(screen.queryByTestId('consultation-summary')).not.toBeInTheDocument()
  })
})

describe('print view', () => {
  it('shows branch header, doctor name and registration number, and MRN', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}/print`]: () =>
        json({
          ...finalized(),
          branch: { name: 'Alpha Main (synthetic)', address: '1 Test Road' },
          tenantName: 'Demo Alpha Hospital',
          timeZone: 'Asia/Kolkata',
          doctor: { name: 'Dr. Rao (synthetic)', registrationNumber: 'KMC-00000', council: 'Synthetic Council', qualifications: 'MBBS' },
          patient: { mrn: 'ALP-0001', name: 'Asha Synthetic-Alpha', dateOfBirth: null, sex: 'female' },
        }),
    })
    renderWithProviders(<App />, { path: `/consultations/${CID}/print`, auth: auth() })
    const sheet = await screen.findByTestId('prescription-print')
    expect(sheet).toHaveTextContent('Alpha Main (synthetic)')
    expect(sheet).toHaveTextContent('1 Test Road')
    expect(screen.getByTestId('print-doctor')).toHaveTextContent('Dr. Rao (synthetic)')
    expect(screen.getByTestId('print-doctor')).toHaveTextContent('Reg. no. KMC-00000 (Synthetic Council)')
    expect(screen.getByTestId('print-patient')).toHaveTextContent('MRN ALP-0001')
    expect(screen.getByTestId('print-patient-age-sex')).toHaveTextContent('Age — · Female')
    expect(screen.queryByTestId('print-missing-reg')).not.toBeInTheDocument()
    expect(within(sheet).getByTestId('prescription-table')).toHaveTextContent('Paracetamol 500 mg')
  })

  it('shows patient age on the prescription date and sex (#128)', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}/print`]: () =>
        json({
          ...finalized(),
          branch: { name: 'Alpha Main (synthetic)', address: null },
          tenantName: 'Demo Alpha Hospital',
          timeZone: 'Asia/Kolkata',
          doctor: { name: 'Dr. Rao (synthetic)', registrationNumber: 'KMC-00000', council: null, qualifications: null },
          // finalized on 2026-10-26: 36 the day before the 37th birthday
          patient: { mrn: 'ALP-0001', name: 'Asha Synthetic-Alpha', dateOfBirth: '1989-10-27', sex: 'male' },
        }),
    })
    renderWithProviders(<App />, { path: `/consultations/${CID}/print`, auth: auth() })
    expect(await screen.findByTestId('print-patient-age-sex')).toHaveTextContent('36 y · Male')
    expect(screen.getByTestId('print-doctor-reg')).toHaveTextContent('Reg. no. KMC-00000')
    expect(screen.getByTestId('print-doctor-reg')).not.toHaveTextContent('(')
  })

  it('an older prescription without a registration number shows "—" and an on-screen warning only (#128)', async () => {
    stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/consultations/${CID}/print`]: () =>
        json({
          ...finalized(),
          branch: null,
          tenantName: 'Demo Alpha Hospital',
          timeZone: 'Asia/Kolkata',
          doctor: { name: 'Dr. Rao (synthetic)', registrationNumber: null, council: null, qualifications: null },
          patient: { mrn: 'ALP-0001', name: 'Asha Synthetic-Alpha', dateOfBirth: null, sex: 'unknown' },
        }),
    })
    renderWithProviders(<App />, { path: `/consultations/${CID}/print`, auth: auth() })
    expect(await screen.findByTestId('print-doctor-reg')).toHaveTextContent('Reg. no. —')
    expect(screen.getByTestId('print-missing-reg')).toHaveClass('print:hidden')
    expect(screen.getByTestId('print-patient-age-sex')).toHaveTextContent('Age — · Sex —')
  })

  it('printing a draft (409) is refused with an explanation', async () => {
    stubFetch({ ...base(['doctor']), [`GET /api/v1/consultations/${CID}/print`]: () => problem(409, 'a draft prescription cannot be printed') })
    renderWithProviders(<App />, { path: `/consultations/${CID}/print`, auth: auth() })
    expect(await screen.findByTestId('print-unavailable')).toHaveTextContent('still a draft')
    expect(screen.queryByTestId('prescription-print')).not.toBeInTheDocument()
  })
})

describe('prescription history on the patient page', () => {
  const detail = {
    id: PATIENT_ID, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female',
    registeredBranchId: ALPHA_MAIN, phone: null, email: null, deletedAt: null,
  }

  it('a doctor sees versions newest first with links', async () => {
    const calls = stubFetch({
      ...base(['doctor']),
      [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(detail),
      'GET /api/v1/consultations': () =>
        json([finalized({ isLatest: false }), consultation({ id: CID2, version: 2, createdOn: '2026-10-26T07:00:00Z', supersedesId: CID })]),
    })
    renderWithProviders(<App />, { path: `/patients/${PATIENT_ID}`, auth: auth() })
    const history = await screen.findByTestId('prescription-history')
    await waitFor(() => expect(within(history).getAllByTestId('prescription-row')).toHaveLength(2))
    const rows = within(history).getAllByTestId('prescription-row')
    expect(rows[0]).toHaveTextContent('Draft')
    expect(rows[1]).toHaveTextContent('v1 (superseded)')
    expect(within(rows[0]!).getByRole('link', { name: 'Open' })).toHaveAttribute('href', `/consultations/${CID2}`)
    const url = new URL(calls.find((c) => c.path === '/api/v1/consultations')!.url, 'http://x')
    expect(url.searchParams.get('patientId')).toBe(PATIENT_ID)
  })

  it('billing sees no prescription history and never requests it', async () => {
    const calls = stubFetch({ ...base(['billing']), [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(detail) })
    renderWithProviders(<App />, { path: `/patients/${PATIENT_ID}`, auth: auth() })
    await screen.findByTestId('patient-details')
    expect(screen.queryByTestId('prescription-history')).not.toBeInTheDocument()
    expect(calls.some((c) => c.path.startsWith('/api/v1/consultations'))).toBe(false)
  })

  it('a deleted patient shows no prescription history', async () => {
    const calls = stubFetch({ ...base(['doctor']), [`GET /api/v1/patients/${PATIENT_ID}`]: () => json({ ...detail, deletedAt: '2026-10-20T00:00:00Z' }) })
    renderWithProviders(<App />, { path: `/patients/${PATIENT_ID}`, auth: auth() })
    await screen.findByTestId('patient-deleted-flag')
    expect(screen.queryByTestId('prescription-history')).not.toBeInTheDocument()
    expect(calls.some((c) => c.path.startsWith('/api/v1/consultations'))).toBe(false)
  })
})
