import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { DR_RAO, PATIENT_ID, branchesResponse, patientRef, practitionersApi, today } from '../../test/schedulingFixtures'
import type { Vitals } from '../../lib/api/types'
import { emptyVitals, toVitalsRequest, validateVitals, type VitalsForm } from './vitalsModel'

afterEach(() => vi.unstubAllGlobals())

// Synthetic Zz-QA data only.
const auth = () => fakeAuthClient({ session: fakeSession() })
const base = (roles: string[]) => ({
  'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
  'GET /api/v1/branches': () => json(branchesResponse),
  'GET /api/v1/practitioners': practitionersApi,
})
const queueEntry = (status: string) => ({
  id: 'q1', branchId: ALPHA_MAIN, queueDate: today(), tokenNo: 7, patientId: PATIENT_ID, patient: patientRef,
  appointmentId: null, practitionerId: DR_RAO, status, checkedInAt: new Date().toISOString(),
})
const reading = (o: Partial<Vitals> = {}): Vitals => ({
  id: 'v1', patientId: PATIENT_ID, queueEntryId: 'q1', branchId: ALPHA_MAIN, recordedOn: '2026-10-27T05:00:00Z', recordedBy: 'u1',
  systolic: 120, diastolic: 80, pulse: 72, temperatureC: 36.8, weightKg: 60, heightCm: 160, bmi: 23.4, spo2: 98, respRate: 16, note: null, flags: [],
  ...o,
})
const problem = (status: number, detail: string) =>
  new Response(JSON.stringify({ title: 'x', status, detail }), { status, headers: { 'Content-Type': 'application/problem+json' } })
const form = (o: Partial<VitalsForm>): VitalsForm => ({ ...emptyVitals(), ...o })

describe('vitals validation (mirrors clinical.record_vitals)', () => {
  it.each([
    ['nothing entered', {}, 'form'],
    ['only a note', { note: 'x' }, 'form'],
    ['systolic without diastolic', { systolic: '120' }, 'diastolic'],
    ['diastolic without systolic', { diastolic: '80' }, 'systolic'],
    ['systolic below 50', { systolic: '49', diastolic: '30' }, 'systolic'],
    ['systolic above 300', { systolic: '301', diastolic: '80' }, 'systolic'],
    ['diastolic below 20', { systolic: '120', diastolic: '19' }, 'diastolic'],
    ['diastolic not lower than systolic', { systolic: '120', diastolic: '120' }, 'diastolic'],
    ['fractional systolic', { systolic: '120.5', diastolic: '80' }, 'systolic'],
    ['pulse below 20', { pulse: '19' }, 'pulse'],
    ['pulse above 250', { pulse: '251' }, 'pulse'],
    ['temperature below 30', { temperatureC: '29.9' }, 'temperatureC'],
    ['temperature above 45', { temperatureC: '45.1' }, 'temperatureC'],
    ['weight below 0.3', { weightKg: '0.2' }, 'weightKg'],
    ['height above 250', { heightCm: '251' }, 'heightCm'],
    ['SpO2 below 0', { spo2: '-1' }, 'spo2'],
    ['SpO2 above 100', { spo2: '101' }, 'spo2'],
    ['fractional SpO2', { spo2: '97.5' }, 'spo2'],
    ['respiratory rate below 4', { respRate: '3' }, 'respRate'],
    ['respiratory rate above 80', { respRate: '81' }, 'respRate'],
    ['not a number', { pulse: 'abc' }, 'pulse'],
    ['note over 500 characters', { pulse: '70', note: 'x'.repeat(501) }, 'note'],
  ] as const)('rejects %s', (_name, values, field) => {
    expect(validateVitals(form(values))).toHaveProperty(field)
  })

  it.each([
    ['SpO2 0 (flagged, not rejected)', { spo2: '0' }],
    ['SpO2 100', { spo2: '100' }],
    ['a full normal set', { systolic: '120', diastolic: '80', pulse: '72', temperatureC: '36.8', weightKg: '60', heightCm: '160', spo2: '98', respRate: '16' }],
    ['high but possible values', { systolic: '190', diastolic: '110', pulse: '140', temperatureC: '40' }],
  ] as const)('accepts %s', (_name, values) => {
    expect(validateVitals(form(values))).toEqual({})
  })

  it('sends only the values entered, as numbers, with the visit and double-submit key', () => {
    expect(toVitalsRequest(form({ systolic: '120', diastolic: '80', temperatureC: '36.8', note: '  ok ' }), 'q1', 'k1')).toEqual({
      queueEntryId: 'q1', clientId: 'k1', systolic: 120, diastolic: 80, temperatureC: 36.8, note: 'ok',
    })
  })
})

describe('vitals from the queue', () => {
  it('a nurse records vitals; invalid values are never sent; out-of-range values are flagged', async () => {
    let saved: Vitals[] = []
    const calls = stubFetch({
      ...base(['nurse']),
      'GET /api/v1/queue': () => json([queueEntry('waiting')]),
      'GET /api/v1/consultations/vitals': () => json(saved),
      'POST /api/v1/consultations/vitals': () => {
        saved = [reading({ systolic: 150, diastolic: 95, flags: [{ field: 'systolic', level: 'high' }, { field: 'diastolic', level: 'high' }] })]
        return json(saved[0])
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Vitals for token 7' }))
    const panel = await screen.findByTestId('vitals-panel')
    expect(await within(panel).findByTestId('vitals-empty')).toBeInTheDocument()

    await user.type(within(panel).getByLabelText('SpO2'), '101')
    await user.click(within(panel).getByTestId('vitals-save'))
    expect(await within(panel).findByText('SpO2 must be a whole number from 0 to 100')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)

    await user.clear(within(panel).getByLabelText('SpO2'))
    await user.type(within(panel).getByLabelText('BP systolic'), '150')
    await user.type(within(panel).getByLabelText('BP diastolic'), '95')
    await user.click(within(panel).getByTestId('vitals-save'))
    expect(await within(panel).findByTestId('vitals-saved')).toBeInTheDocument()
    const posts = calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/consultations/vitals')
    expect(posts).toHaveLength(1)
    expect(posts[0]!.body).toMatchObject({ queueEntryId: 'q1', systolic: 150, diastolic: 95 })
    expect(posts[0]!.body).not.toHaveProperty('tenantId')
    expect(await within(panel).findByTestId('vitals-flag-systolic')).toHaveTextContent('Systolic BP high')
  })

  it('a double click sends one reading', async () => {
    let release!: () => void
    const calls = stubFetch({
      ...base(['nurse']),
      'GET /api/v1/queue': () => json([queueEntry('in_consultation')]),
      'GET /api/v1/consultations/vitals': () => json([]),
      'POST /api/v1/consultations/vitals': () => new Promise<Response>((r) => { release = () => r(json(reading())) }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Vitals for token 7' }))
    const panel = await screen.findByTestId('vitals-panel')
    await user.type(within(panel).getByLabelText('Pulse'), '72')
    await user.dblClick(within(panel).getByTestId('vitals-save'))
    await waitFor(() => expect(calls.filter((c) => c.method === 'POST')).toHaveLength(1))
    release()
    expect(await within(panel).findByTestId('vitals-saved')).toBeInTheDocument()
    expect(calls.filter((c) => c.method === 'POST')).toHaveLength(1)
  })

  it('a server refusal (409 cancelled visit) is explained and nothing is cleared', async () => {
    stubFetch({
      ...base(['nurse']),
      'GET /api/v1/queue': () => json([queueEntry('waiting')]),
      'GET /api/v1/consultations/vitals': () => json([]),
      'POST /api/v1/consultations/vitals': () => problem(409, 'vitals cannot be recorded for a cancelled visit'),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    await user.click(await screen.findByRole('button', { name: 'Vitals for token 7' }))
    const panel = await screen.findByTestId('vitals-panel')
    await user.type(within(panel).getByLabelText('Pulse'), '72')
    await user.click(within(panel).getByTestId('vitals-save'))
    expect(await within(panel).findByText('Not saved: vitals cannot be recorded for a cancelled visit.')).toBeInTheDocument()
    expect(within(panel).getByLabelText('Pulse')).toHaveValue(72)
  })

  it('front desk gets no vitals button and never requests vitals', async () => {
    const calls = stubFetch({ ...base(['receptionist']), 'GET /api/v1/queue': () => json([queueEntry('waiting')]) })
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    expect(await screen.findByLabelText('Token 7')).toBeInTheDocument()
    expect(screen.queryByTestId('queue-vitals-toggle')).not.toBeInTheDocument()
    expect(calls.some((c) => c.path.startsWith('/api/v1/consultations'))).toBe(false)
  })

  it('a finished visit has no vitals button', async () => {
    stubFetch({ ...base(['nurse']), 'GET /api/v1/queue': () => json([queueEntry('done')]) })
    renderWithProviders(<App />, { path: '/queue', auth: auth() })
    expect(await screen.findByLabelText('Token 7')).toBeInTheDocument()
    expect(screen.queryByTestId('queue-vitals-toggle')).not.toBeInTheDocument()
  })
})

describe('vitals in the consultation and patient history', () => {
  const detail = {
    id: PATIENT_ID, mrn: 'ALP-0001', firstName: 'Asha', lastName: 'Synthetic-Alpha', dateOfBirth: '1990-01-01', sex: 'female',
    registeredBranchId: ALPHA_MAIN, phone: null, email: null, deletedAt: null,
  }

  it('the patient page lists readings newest first with flags, queried by patient', async () => {
    const calls = stubFetch({
      ...base(['nurse']),
      [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(detail),
      'GET /api/v1/consultations': () => json([]),
      'GET /api/v1/consultations/vitals': () =>
        json([reading({ id: 'v2', recordedOn: '2026-10-27T07:00:00Z', spo2: 88, flags: [{ field: 'spo2', level: 'critical' }] }), reading()]),
    })
    renderWithProviders(<App />, { path: `/patients/${PATIENT_ID}`, auth: auth() })
    const history = await screen.findByTestId('vitals-history')
    await waitFor(() => expect(within(history).getAllByTestId('vitals-history-row')).toHaveLength(2))
    const rows = within(history).getAllByTestId('vitals-history-row')
    expect(within(rows[0]!).getByTestId('vitals-flag-spo2')).toHaveTextContent('SpO2 critically low')
    expect(within(rows[1]!).queryByTestId('vitals-flags')).not.toBeInTheDocument()
    expect(rows[1]).toHaveTextContent('BP 120/80')
    const url = new URL(calls.find((c) => c.path === '/api/v1/consultations/vitals')!.url, 'http://x')
    expect(url.searchParams.get('patientId')).toBe(PATIENT_ID)
  })

  it("the doctor sees the nurse's readings for this visit in the consultation", async () => {
    const c = {
      id: 'c1', branchId: ALPHA_MAIN, patientId: PATIENT_ID, practitionerId: DR_RAO, practitionerName: 'Dr. Rao (synthetic)', queueEntryId: 'q1',
      appointmentId: null, rootId: 'c1', version: 1, supersedesId: null, isLatest: true, status: 'draft', chiefComplaint: null, notes: null,
      diagnosisText: null, diagnosisCode: null, followUpDate: null, advice: null, finalizedOn: null, rowVersion: 1,
      createdOn: '2026-10-27T05:00:00Z', updatedOn: '2026-10-27T05:00:00Z', lines: [],
    }
    const calls = stubFetch({
      ...base(['doctor']),
      'GET /api/v1/consultations/c1': () => json(c),
      'GET /api/v1/consultations/vitals': () => json([reading({ temperatureC: 38.6, flags: [{ field: 'temperature', level: 'high' }] })]),
    })
    renderWithProviders(<App />, { path: '/consultations/c1', auth: auth() })
    const panel = await screen.findByTestId('vitals-panel')
    expect(await within(panel).findByTestId('vitals-flag-temperature')).toHaveTextContent('Temperature high')
    expect(within(panel).getByTestId('vitals-form')).toBeInTheDocument()
    const url = new URL(calls.find((x) => x.path === '/api/v1/consultations/vitals')!.url, 'http://x')
    expect(url.searchParams.get('queueEntryId')).toBe('q1')
  })

  it('billing sees no vitals and never requests them', async () => {
    const calls = stubFetch({ ...base(['billing']), [`GET /api/v1/patients/${PATIENT_ID}`]: () => json(detail) })
    renderWithProviders(<App />, { path: `/patients/${PATIENT_ID}`, auth: auth() })
    await screen.findByTestId('patient-details')
    expect(screen.queryByTestId('vitals-history')).not.toBeInTheDocument()
    expect(calls.some((c) => c.path.startsWith('/api/v1/consultations'))).toBe(false)
  })
})
