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
    'GET /health/live': () => json({ status: 'Healthy' }),
  })
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
})
