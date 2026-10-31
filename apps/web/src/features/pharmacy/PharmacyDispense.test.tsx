import { afterEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'
import { screen, waitFor, within } from '@testing-library/react'
import { App } from '../../App'
import { ROLE_PERMISSIONS } from '../../lib/permissions'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const store = { id: 'st-ph', code: 'STR-0002', branchId: ALPHA_MAIN, name: 'Zz-QA OP Pharmacy', storeKind: 'op_pharmacy', drugLicenceNo: 'DL-1', licenceValidTo: '2099-01-01', isActive: true }
const ward = { ...store, id: 'st-ward', name: 'Ward', storeKind: 'ward' }
const queue = [
  { id: 'rx-1', branchId: ALPHA_MAIN, patientId: 'p1', patientName: 'Ravi Synthetic-Alpha', patientMrn: 'ALP-0002', doctorName: 'Dr Zz-QA', finalizedOn: '2026-10-27T04:00:00Z', validThrough: '2026-11-26', expired: false, lineCount: 2, status: 'pending', patientAgeYears: 41, patientSex: 'male', patientDobEstimated: false, patientAllergies: 'Penicillin' },
  { id: 'rx-2', branchId: ALPHA_MAIN, patientId: 'p2', patientName: 'Kiran Synthetic-Alpha', patientMrn: 'MRN-1001', doctorName: 'Dr Zz-QA', finalizedOn: '2026-10-27T05:00:00Z', lineCount: 1, status: 'partial' },
]
const line = (lineNo: number, extra: object) => ({
  id: `l${lineNo}`, lineNo, medicineName: lineNo === 1 ? 'Amoxicillin' : 'Paracetamol', strength: null, dose: '1 cap', frequency: '1-0-1',
  durationDays: 5, route: null, foodTiming: null, instructions: null, inventoryItemId: 'it-1', dispensedBase: 0, complete: false, availableBase: 56, ...extra,
})
const rx = {
  id: 'rx-1', branchId: ALPHA_MAIN, patientId: 'p1', patientName: 'Ravi Synthetic-Alpha', patientMrn: 'ALP-0002', practitionerId: 'pr', doctorName: 'Dr Zz-QA',
  finalizedOn: '2026-10-27T04:00:00Z', version: 1, diagnosisText: null, superseded: false, status: 'pending',
  lines: [line(1, {}), line(2, { inventoryItemId: null, availableBase: null })], dispenses: [],
}
const after = {
  ...rx, status: 'partial',
  lines: [line(1, { dispensedBase: 10, availableBase: 46 }), line(2, { inventoryItemId: null, availableBase: null })],
  dispenses: [{ id: 'd1', storeId: store.id, dispensedBy: 'u', createdOn: '2026-10-27T06:00:00Z', note: null,
    lines: [{ prescriptionLineId: 'l1', itemId: 'it-1', brandName: 'Zz-QA Amoxy', batchId: 'b1', batchNo: 'SOON', expiryDate: '2030-01-31', qtyBase: 10, completesLine: false }] }],
}

function stubFetchRx(prescription: object) {
  return stub('pharmacist', undefined, prescription)
}

function stub(role: string, dispense: () => Response = () => json(after), prescription: object = rx) {
  return stubFetch({
    'GET /api/v1/me': () => json({ ...meFor({ roles: [role] }), permissions: [...(ROLE_PERMISSIONS[role] ?? [])] }),
    'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'MAIN', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true }]),
    'GET /api/v1/inventory/pharmacy/queue': () => json(queue),
    'GET /api/v1/inventory/pharmacy/prescriptions/rx-1': () => json(prescription),
    'GET /api/v1/inventory/stores': () => json([store, ward]),
    'GET /api/v1/inventory/items': () => json({ items: [], uoms: [] }),
    'POST /api/v1/inventory/pharmacy/dispenses': dispense,
    'GET /health/live': () => json({ status: 'Healthy' }),
  })
}

describe('Pharmacy dispensing', () => {
  it('shows age, sex and allergies in the queue, and warns when allergies are not recorded (#275)', async () => {
    stub('pharmacist')
    renderWithProviders(<App />, { path: '/pharmacy/dispense', auth: fakeAuthClient({ session: fakeSession() }) })
    const rows = await screen.findAllByTestId('pharmacy-queue-row')
    expect(rows[0]).toHaveTextContent('41 y · male')
    expect(within(rows[0]!).getByTestId('pharmacy-allergies')).toHaveTextContent('Allergies: Penicillin')
    expect(within(rows[1]!).getByTestId('pharmacy-allergies-missing')).toHaveTextContent('Allergies not recorded')
  })

  it('shows the allergies prominently on the dispense page before dispensing (#275)', async () => {
    stubFetchRx({ ...rx, patientAgeYears: 7, patientDobEstimated: true, patientSex: 'female', patientAllergies: 'Sulfa; Ibuprofen' })
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('pharmacy-allergies')).toHaveTextContent('Allergies: Sulfa; Ibuprofen')
    expect(screen.getByTestId('rx-patient-age-sex')).toHaveTextContent('7 y (approx.) · female')
  })

  it('warns the pharmacist when allergies are not recorded (#275)', async () => {
    stubFetchRx({ ...rx, patientAgeYears: null, patientSex: 'unknown', patientAllergies: null })
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByTestId('pharmacy-allergies-missing')).toHaveTextContent('Ask the patient about drug allergies')
    expect(screen.queryByTestId('rx-patient-age-sex')).not.toBeInTheDocument()
  })

  it('shows the pharmacist the queue oldest first with patient, doctor and status', async () => {
    stub('pharmacist')
    renderWithProviders(<App />, { path: '/pharmacy/dispense', auth: fakeAuthClient({ session: fakeSession() }) })
    const rows = await screen.findAllByTestId('pharmacy-queue-row')
    expect(rows).toHaveLength(2)
    expect(rows[0]).toHaveTextContent('Ravi Synthetic-Alpha')
    expect(rows[0]).toHaveTextContent('ALP-0002')
    expect(rows[0]).toHaveTextContent('Dr Zz-QA')
    expect(within(rows[0]!).getByTestId('rx-status')).toHaveTextContent('Pending')
    expect(within(rows[1]!).getByTestId('rx-status')).toHaveTextContent('Partly dispensed')
    expect(screen.getByRole('link', { name: 'Prescriptions to dispense' })).toBeInTheDocument()
  })

  it('dispenses part of a line with an idempotency key and never sends a tenant id', async () => {
    const user = userEvent.setup()
    const calls = stub('pharmacist')
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
    expect(within(screen.getByTestId('dispense-store')).queryByText('Ward')).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Quantity for line 1'), '10')
    await user.click(within(screen.getAllByTestId('rx-line')[0]!).getByTestId('rx-line-complete'))
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText(/Some medicines are still open/)).toBeInTheDocument()
    const posted = calls.find((c) => c.method === 'POST' && c.path === '/api/v1/inventory/pharmacy/dispenses')
    expect(posted?.headers.get('Idempotency-Key')).toMatch(/^[0-9a-f-]{36}$/i)
    expect(posted?.body).toEqual({ consultationId: 'rx-1', storeId: store.id, lines: [{ lineNo: 1, qtyBase: 10, complete: false }] })
    expect(JSON.stringify(posted?.body)).not.toMatch(/tenant/i)
    expect(await screen.findByTestId('rx-dispenses')).toHaveTextContent('batch SOON')
  })

  it('asks for a quantity and for an item on an unlinked line', async () => {
    const user = userEvent.setup()
    const calls = stub('pharmacist')
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText('Enter a quantity for at least one medicine.')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Quantity for line 2'), '4')
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText('Line 2: choose the stock item to give.')).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
  })

  it('needs a reason before giving more than prescribed (#187)', async () => {
    const user = userEvent.setup()
    const capped = { ...rx, lines: [line(1, { prescribedBase: 10, dispensedBase: 4 }), line(2, { inventoryItemId: null, availableBase: null, prescribedBase: null })] }
    const calls2 = stubFetch({
      'GET /api/v1/me': () => json({ ...meFor({ roles: ['pharmacist'] }), permissions: [...(ROLE_PERMISSIONS.pharmacist ?? [])] }),
      'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'MAIN', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true }]),
      'GET /api/v1/inventory/pharmacy/queue': () => json(queue),
      'GET /api/v1/inventory/pharmacy/prescriptions/rx-1': () => json(capped),
      'GET /api/v1/inventory/stores': () => json([store, ward]),
      'GET /api/v1/inventory/items': () => json({ items: [], uoms: [] }),
      'POST /api/v1/inventory/pharmacy/dispenses': () => json(after),
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
    expect(screen.getAllByTestId('rx-line-prescribed')[0]).toHaveTextContent('10')
    expect(screen.getAllByTestId('rx-line-prescribed')[1]).toHaveTextContent('—')
    // Exactly the rest of the prescription: no warning.
    await user.type(screen.getByLabelText('Quantity for line 1'), '6')
    expect(screen.queryByTestId('rx-line-over-warning')).not.toBeInTheDocument()
    // One over: warning, and submit is refused until a reason is given.
    await user.clear(screen.getByLabelText('Quantity for line 1'))
    await user.type(screen.getByLabelText('Quantity for line 1'), '7')
    expect(screen.getByTestId('rx-line-over-warning')).toBeInTheDocument()
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText(/Line 1: 7 is more than prescribed \(10 prescribed, 4 given\)/)).toBeInTheDocument()
    expect(calls2.some((c) => c.method === 'POST')).toBe(false)
    await user.type(screen.getByTestId('rx-line-override-reason'), 'Zz-QA strip cannot be split')
    await user.click(screen.getByTestId('dispense-submit'))
    await waitFor(() => expect(calls2.some((c) => c.method === 'POST')).toBe(true))
    const posted = calls2.find((c) => c.method === 'POST')
    expect(posted?.body).toEqual({ consultationId: 'rx-1', storeId: store.id,
      lines: [{ lineNo: 1, qtyBase: 7, complete: true, overrideReason: 'Zz-QA strip cannot be split' }] })
  })

  it('shows the server refusal for a stock-out', async () => {
    const user = userEvent.setup()
    stub('pharmacist', () => json({ title: 'Conflict', status: 409, detail: 'Not enough stock: only 56 in stock.' }, 409))
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
    await user.type(screen.getByLabelText('Quantity for line 1'), '57')
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText(/only 56 in stock/)).toBeInTheDocument()
  })

  it('shows how long each prescription stays valid (#188)', async () => {
    stub('pharmacist')
    renderWithProviders(<App />, { path: '/pharmacy/dispense', auth: fakeAuthClient({ session: fakeSession() }) })
    const cells = await screen.findAllByTestId('pharmacy-queue-valid-through')
    expect(cells[0]).toHaveTextContent('26 Nov 2026')
    expect(cells[0]).toHaveAttribute('data-expired', 'false')
    expect(cells[1]).toHaveTextContent('—')
  })

  it('shows the server refusal for an expired prescription (#188)', async () => {
    const user = userEvent.setup()
    stub('pharmacist', () => json({ title: 'Conflict', status: 409, detail: 'prescription expired on 2026-10-29' }, 409))
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
    await user.type(screen.getByLabelText('Quantity for line 1'), '2')
    await user.click(screen.getByTestId('dispense-submit'))
    expect(await screen.findByText(/prescription expired on 2026-10-29/)).toBeInTheDocument()
  })

  it('keeps the queue off the menu for a receptionist', async () => {
    stubFetch({
      'GET /api/v1/me': () => json({ ...meWithRoles(['receptionist']), permissions: [...ROLE_PERMISSIONS.receptionist!] }),
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByRole('link', { name: 'Dashboard' })
    expect(screen.queryByRole('link', { name: 'Prescriptions to dispense' })).not.toBeInTheDocument()
  })
})

// Barcode scanning at the counter. Synthetic GS1 strings only (GTINs 0890123456xxxx are made up).
describe('Pharmacy dispensing: scan the pack', () => {
  const yy = String((new Date().getFullYear() + 2) % 100).padStart(2, '0')
  const item = (id: string, brandName: string, genericName: string) => ({
    id, code: `ITM-${id}`, itemKind: 'drug', brandName, genericName, strength: null, dosageForm: 'tablet', route: null,
    manufacturerName: 'Zz-QA Labs', scheduleCode: 'H', hsnCode: '3004', gstRateBp: 1200, baseUomCode: 'TAB',
    isColdChain: false, isHighAlert: false, isLasa: false, isActive: true, packs: [],
  })
  const AMOX = item('it-1', 'Zz-QA Amoxy 500', 'Amoxicillin')
  const PARA = item('it-2', 'Zz-QA Para 650', 'Paracetamol')
  const CETI = item('it-3', 'Zz-QA Ceti 10', 'Cetirizine')
  const links: Record<string, object | null> = { '08901234567807': AMOX, '08901234567814': PARA, '08901234567821': CETI, '09999999999994': null }

  function stubScan() {
    const routes: Record<string, () => Response> = {
      'GET /api/v1/me': () => json({ ...meFor({ roles: ['pharmacist'] }), permissions: [...(ROLE_PERMISSIONS.pharmacist ?? [])] }),
      'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'MAIN', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true }]),
      'GET /api/v1/inventory/pharmacy/queue': () => json(queue),
      'GET /api/v1/inventory/pharmacy/prescriptions/rx-1': () => json(rx),
      'GET /api/v1/inventory/stores': () => json([store, ward]),
      'GET /api/v1/inventory/items': () => json({ items: [AMOX, PARA, CETI], uoms: [] }),
      'POST /api/v1/inventory/pharmacy/dispenses': () => json(after),
      'GET /health/live': () => json({ status: 'Healthy' }),
    }
    for (const [gtin, linked] of Object.entries(links)) routes[`GET /api/v1/inventory/gtin/${gtin}`] = () => json({ gtin, item: linked })
    return stubFetch(routes)
  }
  async function open() {
    renderWithProviders(<App />, { path: '/pharmacy/dispense/rx-1', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByTestId('pharmacy-dispense-page')
    await waitFor(() => expect(screen.getByTestId('dispense-store')).toHaveValue(store.id))
  }
  const scan = async (user: ReturnType<typeof userEvent.setup>, code: string) => {
    await user.clear(screen.getByTestId('dispense-scan-input'))
    await user.type(screen.getByTestId('dispense-scan-input'), `${code}{Enter}`)
  }
  const posted = (calls: ReturnType<typeof stubFetch>) => calls.find((c) => c.method === 'POST' && c.path === '/api/v1/inventory/pharmacy/dispenses')?.body as { lines: object[] }

  it('a scan selects the prescribed line and its batch, and the batch is sent', async () => {
    const user = userEvent.setup()
    const calls = stubScan()
    await open()
    await scan(user, `(01)08901234567807(17)${yy}0630(10)ZZQA-B1(21)SN1`)
    expect(await screen.findByTestId('dispense-scan-matched')).toHaveTextContent('Line 1: Zz-QA Amoxy 500, batch ZZQA-B1')
    expect(within(screen.getAllByTestId('rx-line')[0]!).getByTestId('rx-line-batch')).toHaveTextContent('Scanned batch ZZQA-B1')
    await user.type(screen.getByLabelText('Quantity for line 1'), '5')
    await user.click(screen.getByTestId('dispense-submit'))
    await waitFor(() => expect(posted(calls)).toBeDefined())
    expect(posted(calls).lines).toEqual([expect.objectContaining({ lineNo: 1, qtyBase: 5, batchNo: 'ZZQA-B1' })])
    expect(JSON.stringify(posted(calls))).not.toMatch(/tenant/i)
  })

  it('a scan fills the item on an unlinked line by medicine name', async () => {
    const user = userEvent.setup()
    const calls = stubScan()
    await open()
    await scan(user, `]d2010890123456781417${yy}123110ZZQA-P1`)
    expect(await screen.findByTestId('dispense-scan-matched')).toHaveTextContent('Line 2')
    await user.type(screen.getByLabelText('Quantity for line 2'), '3')
    await user.click(screen.getByTestId('dispense-submit'))
    await waitFor(() => expect(posted(calls)).toBeDefined())
    expect(posted(calls).lines).toEqual([expect.objectContaining({ lineNo: 2, itemId: 'it-2', qtyBase: 3, batchNo: 'ZZQA-P1' })])
  })

  it('warns on a drug that is not on the prescription and selects nothing', async () => {
    const user = userEvent.setup()
    stubScan()
    await open()
    await scan(user, `(01)08901234567821(17)${yy}0630(10)ZZQA-C1`)
    expect(await screen.findByTestId('dispense-scan-wrong')).toHaveTextContent('Wrong drug? Zz-QA Ceti 10 (Cetirizine) is not on this prescription')
    expect(screen.queryByTestId('rx-line-batch')).not.toBeInTheDocument()
  })

  it('blocks an expired pack before looking it up', async () => {
    const user = userEvent.setup()
    const calls = stubScan()
    await open()
    await scan(user, '(01)08901234567807(17)200131(10)ZZQA-OLD')
    expect(await screen.findByTestId('dispense-scan-expired')).toHaveTextContent('This pack expired on 2020-01-31')
    expect(calls.some((c) => c.path.startsWith('/api/v1/inventory/gtin/'))).toBe(false)
    expect(screen.queryByTestId('rx-line-batch')).not.toBeInTheDocument()
  })

  it('explains an unlinked barcode', async () => {
    const user = userEvent.setup()
    stubScan()
    await open()
    await scan(user, `(01)09999999999994(17)${yy}0630(10)ZZQA-X`)
    expect(await screen.findByTestId('dispense-scan-unlinked')).toHaveTextContent('not linked to a stock item yet')
  })
})
