import { afterEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'
import { screen, waitFor } from '@testing-library/react'
import { App } from '../../App'
import { ROLE_PERMISSIONS } from '../../lib/permissions'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const uoms = [
  { code: 'TAB', name: 'Tablet' },
  { code: 'STRIP', name: 'Strip' },
]
const item = {
  id: 'it-1',
  code: 'ITM-0001',
  itemKind: 'drug',
  brandName: 'Crocin',
  genericName: 'Paracetamol',
  strength: '500 mg',
  dosageForm: 'Tablet',
  route: null,
  manufacturerName: 'GSK',
  scheduleCode: 'H',
  hsnCode: '30049099',
  gstRateBp: 1200,
  baseUomCode: 'TAB',
  isColdChain: false,
  isHighAlert: false,
  isLasa: false,
  isActive: true,
  packs: [{ uomCode: 'STRIP', unitsPerPack: 10, isPurchase: true, isSale: true }],
}
const store = {
  id: 'st-1',
  code: 'STR-0001',
  branchId: ALPHA_MAIN,
  name: 'Main store',
  storeKind: 'main',
  drugLicenceNo: null,
  licenceValidTo: null,
  isActive: true,
}

function stub(role: string) {
  return stubFetch({
    'GET /api/v1/me': () => json({ ...meFor({ roles: [role] }), permissions: [...(ROLE_PERMISSIONS[role] ?? [])] }),
    'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'MAIN', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true }]),
    'GET /api/v1/inventory/items': () => json({ items: [item], uoms }),
    'GET /api/v1/inventory/stores': () => json([store]),
    'GET /api/v1/inventory/stock': () =>
      json([
        {
          storeId: store.id,
          storeCode: store.code,
          storeName: store.name,
          itemId: item.id,
          itemCode: item.code,
          brandName: item.brandName,
          batchId: 'ba-1',
          batchNo: 'OLD',
          expiryDate: '2020-01-01',
          mrpPaise: 1500,
          purchaseRatePaise: 900,
          onHandBase: 4,
          baseUomCode: 'TAB',
          minQty: 10,
          lowStock: true,
          expiryState: 'expired',
        },
      ]),
    'POST /api/v1/inventory/items': () => json({ ...item, code: 'ITM-0002', brandName: 'Crocin' }),
    'POST /api/v1/inventory/opening-stock': () =>
      json({
        id: 'op-1',
        docNo: 'OPN-0001',
        storeId: store.id,
        approvalRequestId: 'ap-1',
        approverId: '0a000000-0000-4000-8000-000000000001',
        lines: [],
      }),
    'GET /api/v1/inventory/stock/alerts': () => json(alerts()),
    'PUT /api/v1/inventory/stores/st-1/items/it-1/reorder': () => json({ storeId: 'st-1', itemId: 'it-1', reorderLevel: 20, reorderQty: 50 }),
    'PUT /api/v1/inventory/settings': () => json({ rxValidityDays: 30, nearExpiryDays: 60 }),
    'GET /api/v1/inventory/gtin/08901234567890': () => json({ gtin: '08901234567890', item }),
    'GET /api/v1/inventory/gtin/09999999999994': () => json({ gtin: '09999999999994', item: null }),
    'POST /api/v1/inventory/gtin': () => json({ gtin: '09999999999994', item }),
    'GET /health/live': () => json({ status: 'Healthy' }),
  })
}

const GS = '\u001d'
const yy = (add: number) => String((new Date().getFullYear() + add) % 100).padStart(2, '0')

function isoIn(days: number) {
  const d = new Date()
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

function alerts() {
  const base = { storeId: store.id, storeName: store.name, itemId: item.id, itemCode: item.code, brandName: item.brandName, baseUomCode: 'TAB', mrpPaise: 1500 }
  return {
    nearExpiryDays: 90,
    counts: { lowStock: 1, nearExpiry: 1, expired: 1 },
    lowStock: [{ ...base, storeCode: store.code, branchId: ALPHA_MAIN, onHandBase: 4, reorderLevel: 10, reorderQty: null, suggestedQty: 6 }],
    expiry: [
      { ...base, kind: 'expired', batchId: 'ba-1', batchNo: 'ZZQA-OLD', expiryDate: isoIn(-3), daysLeft: -3, onHandBase: 4, valuePaise: 6000 },
      { ...base, kind: 'near_expiry', batchId: 'ba-2', batchNo: 'ZZQA-SOON', expiryDate: isoIn(20), daysLeft: 20, onHandBase: 10, valuePaise: 15000 },
    ],
  }
}

function renderStock(role: string) {
  const calls = stub(role)
  renderWithProviders(<App />, { path: '/stock', auth: fakeAuthClient({ session: fakeSession() }) })
  return calls
}

describe('Stock page', () => {
  it('lets an admin add an item and shows the assigned code', async () => {
    const user = userEvent.setup()
    const calls = renderStock('tenant_admin')
    expect(await screen.findByRole('tab', { name: 'Opening stock' })).toBeInTheDocument()
    expect(await screen.findByText('The item code is assigned when you save.')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Brand name'), 'Crocin')
    await user.type(screen.getByLabelText('Generic name'), 'Paracetamol')
    await user.type(screen.getByLabelText('Maker'), 'GSK')
    await user.selectOptions(screen.getByLabelText('Schedule'), 'H')
    await user.type(screen.getByLabelText('HSN'), '30049099')
    await user.selectOptions(screen.getByLabelText('GST'), '1200')
    await user.selectOptions(screen.getByLabelText('Base unit'), 'TAB')
    await user.click(screen.getByRole('button', { name: 'Save item' }))
    expect(await screen.findByText('Saved. The item code is ITM-0002.')).toBeInTheDocument()
    const posted = calls.find((c) => c.method === 'POST' && c.path === '/api/v1/inventory/items')
    expect(posted?.body).toMatchObject({ brandName: 'Crocin', gstRateBp: 1200, baseUomCode: 'TAB', scheduleCode: 'H' })
    expect(posted?.body).not.toHaveProperty('code')
    expect(posted?.body).not.toHaveProperty('id')
  })

  it('posts opening stock with an idempotency key and records the poster as approver', async () => {
    const user = userEvent.setup()
    const calls = renderStock('tenant_admin')
    await user.click(await screen.findByRole('tab', { name: 'Opening stock' }))
    expect(await screen.findByText(/recorded as the approver/i)).toBeInTheDocument()
    await user.type(screen.getByLabelText('Batch number on the pack'), 'B1')
    await user.type(screen.getByLabelText('Expiry'), '2030-06-01')
    await user.type(screen.getByLabelText('MRP (rupees)'), '15')
    await user.type(screen.getByLabelText('Purchase rate (rupees)'), '12.50')
    await user.type(screen.getByLabelText('Quantity'), '10')
    await user.click(screen.getByRole('button', { name: 'Save opening stock' }))
    expect(await screen.findByText(/Opening stock OPN-0001/)).toBeInTheDocument()
    const posted = calls.find((c) => c.path === '/api/v1/inventory/opening-stock')
    expect(posted?.headers.get('Idempotency-Key')).toMatch(/^[0-9a-f-]{36}$/i)
    expect(posted?.body).toMatchObject({
      storeId: store.id,
      lines: [{ itemId: item.id, batchNo: 'B1', mrpPaise: 1500, purchaseRatePaise: 1250, qtyBase: 10 }],
    })
    expect(posted?.body).not.toHaveProperty('docNo')
  })

  it('a GS1 scan fills item, batch and expiry on opening stock', async () => {
    const user = userEvent.setup()
    renderStock('tenant_admin')
    await user.click(await screen.findByRole('tab', { name: 'Opening stock' }))
    const scan = await screen.findByTestId('opening-scan-input')
    // Synthetic DataMatrix payload from a keyboard-wedge scanner: AIM prefix, FNC1 as GS, Enter at the end.
    await user.click(scan)
    await user.paste(`]d2010890123456789017${yy(2)}063010ZZQA-B1${GS}21SN1`)
    await user.keyboard('{Enter}')
    expect(await screen.findByTestId('opening-scan-filled')).toHaveTextContent('Scanned Crocin: filled item, batch, expiry')
    expect(screen.getByLabelText('Batch number on the pack')).toHaveValue('ZZQA-B1')
    expect(screen.getByLabelText('Expiry')).toHaveValue(`${new Date().getFullYear() + 2}-06-30`)
  })

  it('an unknown GTIN asks once to link it to a catalogue item, then fills the form', async () => {
    const user = userEvent.setup()
    const calls = renderStock('tenant_admin')
    await user.click(await screen.findByRole('tab', { name: 'Opening stock' }))
    await user.click(await screen.findByTestId('opening-scan-input'))
    await user.paste(`(01)09999999999994(17)${yy(1)}1200(10)LOT7`)
    await user.keyboard('{Enter}')
    const prompt = await screen.findByTestId('gtin-link-prompt')
    expect(prompt).toHaveTextContent('09999999999994')
    await user.selectOptions(screen.getByTestId('gtin-link-item'), item.id)
    await user.click(screen.getByTestId('gtin-link-save'))
    expect(await screen.findByTestId('opening-scan-filled')).toHaveTextContent('Crocin')
    expect(screen.queryByTestId('gtin-link-prompt')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Batch number on the pack')).toHaveValue('LOT7')
    expect(screen.getByLabelText('Expiry')).toHaveValue(`${new Date().getFullYear() + 1}-12-31`)
    const posted = calls.find((c) => c.method === 'POST' && c.path === '/api/v1/inventory/gtin')
    expect(posted?.body).toEqual({ gtin: '09999999999994', itemId: item.id })
    expect(posted?.body).not.toHaveProperty('tenantId')
  })

  it('a bad barcode shows why and fills nothing', async () => {
    const user = userEvent.setup()
    renderStock('tenant_admin')
    await user.click(await screen.findByRole('tab', { name: 'Opening stock' }))
    await user.click(await screen.findByTestId('opening-scan-input'))
    await user.paste('0108901234567891')
    await user.keyboard('{Enter}')
    expect(await screen.findByTestId('opening-scan-error')).toHaveTextContent('check digit')
    expect(screen.getByLabelText('Batch number on the pack')).toHaveValue('')
  })

  it('highlights expired stock and hides catalog edits from a pharmacist', async () => {
    const user = userEvent.setup()
    const calls = renderStock('pharmacist')
    expect(await screen.findByRole('tab', { name: 'Items' })).toBeInTheDocument()
    expect(screen.queryByRole('tab', { name: 'Opening stock' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Save item' })).not.toBeInTheDocument()
    expect(await screen.findByText('ITM-0001')).toBeInTheDocument()
    await user.click(screen.getByRole('tab', { name: 'Stock on hand' }))
    const row = await screen.findByText('Expired')
    expect(row.closest('tr')).toHaveAttribute('data-expiry', 'expired')
    expect(screen.getByTestId('low-stock')).toHaveTextContent('Low stock')
    expect(screen.getByTestId('low-stock')).toHaveTextContent('reorder 10')
    await user.click(screen.getByRole('checkbox', { name: 'Below reorder level' }))
    await waitFor(() => {
      const stockCall = calls.find((c) => c.path === '/api/v1/inventory/stock' && c.url.includes('lowStock=true'))
      expect(stockCall).toBeTruthy()
    })
  })

  it('keeps stock off the menu for a receptionist', async () => {
    stubFetch({
      'GET /api/v1/me': () => json({ ...meWithRoles(['receptionist']), permissions: [...ROLE_PERMISSIONS.receptionist!] }),
      'GET /health/live': () => json({ status: 'Healthy' }),
    })
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByRole('link', { name: 'Dashboard' })
    expect(screen.queryByRole('link', { name: 'Stock' })).not.toBeInTheDocument()
  })

  it('shows expiry and low-stock alerts, a nav badge, and saves a reorder level and warning window', async () => {
    const user = userEvent.setup()
    const calls = stub('tenant_admin')
    renderWithProviders(<App />, { path: '/stock?tab=alerts', auth: fakeAuthClient({ session: fakeSession() }) })
    const rows = await screen.findAllByTestId('expiry-alert')
    expect(rows.map((r) => r.getAttribute('data-kind'))).toEqual(['expired', 'near_expiry'])
    expect(screen.getByText('3 days ago')).toBeInTheDocument()
    expect(screen.getByText('in 20 days')).toBeInTheDocument()
    expect(await screen.findByTestId('nav-badge-stock')).toHaveTextContent('3')
    expect(screen.getByTestId('suggested-qty')).toHaveTextContent('6 TAB')
    await user.click(screen.getByTestId('reorder-edit'))
    await user.clear(screen.getByTestId('reorder-level-input'))
    await user.type(screen.getByTestId('reorder-level-input'), '20')
    await user.type(screen.getByTestId('reorder-qty-input'), '50')
    await user.click(screen.getByTestId('reorder-save'))
    await waitFor(() => expect(calls.some((c) => c.method === 'PUT' && c.path.endsWith('/reorder'))).toBe(true))
    expect(calls.find((c) => c.path.endsWith('/reorder'))?.body).toEqual({ reorderLevel: 20, reorderQty: 50 })
    await user.clear(screen.getByTestId('near-expiry-days'))
    await user.type(screen.getByTestId('near-expiry-days'), '400')
    expect(screen.getByTestId('near-expiry-save')).toBeDisabled()
    await user.clear(screen.getByTestId('near-expiry-days'))
    await user.type(screen.getByTestId('near-expiry-days'), '60')
    await user.click(screen.getByTestId('near-expiry-save'))
    await waitFor(() => expect(calls.find((c) => c.method === 'PUT' && c.path === '/api/v1/inventory/settings')?.body).toEqual({ nearExpiryDays: 60 }))
  })

  it('hides the warning-window setting from staff without settings access', async () => {
    stub('pharmacist')
    renderWithProviders(<App />, { path: '/stock?tab=alerts', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findAllByTestId('expiry-alert')).toHaveLength(2)
    expect(screen.queryByTestId('near-expiry-days')).not.toBeInTheDocument()
  })
})
