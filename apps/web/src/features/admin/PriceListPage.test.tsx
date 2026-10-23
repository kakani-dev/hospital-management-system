import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { branchesResponse } from '../../test/schedulingFixtures'
import { localToday } from '../../lib/dates'

afterEach(() => vi.unstubAllGlobals())

const TAX = '11111111-0000-4000-8000-0000000000aa'
const DRESS = 'd1111111-0000-4000-8000-000000000001'
const CONSULT = 'c1111111-0000-4000-8000-000000000001'
const LIST = '11111111-0000-4000-8000-0000000000bb'
const DR = '11111111-0000-4000-8000-0000000000cc'

const taxCodes = [{ id: TAX, code: 'EXEMPT', sacHsnCode: '9993', isExempt: true, rateBp: 0, effectiveFrom: '2017-07-01', effectiveTo: null }]
const consult = {
  id: CONSULT, code: 'CONSULT', name: 'OP consultation', category: 'consultation', taxCodeId: TAX,
  sacHsnCode: '9993', taxRateBp: 0, isExempt: true, isActive: true, isStockTracked: false, hospitalPricePaise: 50000,
}
const dress = {
  id: DRESS, code: 'DRESS', name: 'Wound dressing', category: 'procedure', taxCodeId: TAX,
  sacHsnCode: '9993', taxRateBp: 0, isExempt: true, isActive: true, isStockTracked: false, hospitalPricePaise: 15000,
}

function routes(extra: Parameters<typeof stubFetch>[0] = {}) {
  const catalog = [consult, { ...dress }]
  return stubFetch({
    'GET /api/v1/me': () => json(meFor()),
    'GET /health/live': () => json({ status: 'Healthy' }),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': () => json([{ id: DR, userId: null, displayName: 'Dr. Rao', specialty: null, isActive: true, isDeleted: false }]),
    'GET /api/v1/service-items': () => json(catalog),
    'GET /api/v1/service-items/tax-codes': () => json(taxCodes),
    'GET /api/v1/price-lists': () => json([{ id: LIST, name: 'Standard', branchId: null, isActive: true, isPublicDisplay: false, schemeCode: null }]),
    'GET /api/v1/price-lists/items': () => json([
      { id: 'pr1', priceListId: LIST, priceListName: 'Standard', branchId: null, practitionerId: null, unitPricePaise: 15000, effectiveFrom: '2017-07-01', effectiveTo: null },
    ]),
    'POST /api/v1/service-items': (_u, init) => {
      const body = JSON.parse(String(init.body)) as { id?: string; isActive?: boolean; code?: string; name?: string; category?: string; taxCodeId?: string }
      if (body.id) {
        const row = catalog.find((item) => item.id === body.id)
        if (row && body.isActive !== undefined) row.isActive = body.isActive
        return json({ id: body.id })
      }
      return json({ id: 'new-item' }, 201)
    },
    'POST /api/v1/price-lists/items': () => json({ id: 'price-1' }, 201),
    ...extra,
  })
}

const open = () => renderWithProviders(<App />, { path: '/admin/price-list', auth: fakeAuthClient({ session: fakeSession() }) })

/** Wait until the catalog, tax codes and price lists have all rendered, so a click is not lost on a row that is still being replaced. */
async function settle() {
  await screen.findByRole('option', { name: 'Exempt · SAC 9993' })
  await screen.findByRole('option', { name: 'Standard · Hospital' })
  await screen.findAllByTestId('service-item-row')
}

describe('Price list admin', () => {
  it('lists code, name, category, SAC and the hospital rate', async () => {
    routes()
    open()
    const rows = await screen.findAllByTestId('service-item-row')
    expect(rows.map((row) => row.getAttribute('data-code'))).toEqual(['CONSULT', 'DRESS'])
    expect(rows[1]).toHaveTextContent('Wound dressing')
    expect(rows[1]).toHaveTextContent('Procedure')
    expect(rows[1]).toHaveTextContent('Exempt · SAC 9993')
    expect(rows[1]).toHaveTextContent('₹150.00')
    expect(screen.getByRole('link', { name: 'Price list' })).toHaveAttribute('href', '/admin/price-list')
  })

  it('filters the list as you type', async () => {
    routes()
    const user = userEvent.setup()
    open()
    await screen.findAllByTestId('service-item-row')
    await user.type(screen.getByLabelText('Search services'), 'dress')
    await waitFor(() => expect(screen.getAllByTestId('service-item-row')).toHaveLength(1))
    expect(screen.getByTestId('service-item-row')).toHaveAttribute('data-code', 'DRESS')
  })

  it('adds a service and saves a hospital rate in paise', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    await screen.findByRole('option', { name: 'Exempt · SAC 9993' })
    await user.type(screen.getByLabelText('Code'), 'CERT')
    await user.type(screen.getByLabelText('Name'), 'Medical certificate')
    await user.selectOptions(screen.getByLabelText('Category'), 'other')
    await user.click(screen.getByRole('button', { name: 'Add service' }))
    expect(await screen.findByText('Medical certificate added. Set the rate in the panel.')).toBeInTheDocument()
    expect(calls.find((call) => call.method === 'POST' && call.path === '/api/v1/service-items')!.body).toEqual({
      code: 'CERT', name: 'Medical certificate', category: 'other', taxCodeId: TAX,
    })

    const drawer = await screen.findByTestId('price-drawer')
    await user.type(within(drawer).getByLabelText('Amount (rupees)'), '200')
    await user.click(within(drawer).getByRole('button', { name: 'Save price' }))
    expect(await screen.findByText(new RegExp(`₹200\\.00 saved for Medical certificate at the hospital, from`))).toBeInTheDocument()
    expect(calls.find((call) => call.method === 'POST' && call.path === '/api/v1/price-lists/items')!.body).toEqual({
      serviceItemId: 'new-item',
      unitPricePaise: 20000,
      effectiveFrom: localToday(),
    })
  })

  it('shows price_overlap when the period already has a rate', async () => {
    const calls = routes({
      'POST /api/v1/price-lists/items': () =>
        json({ title: 'Conflict', status: 409, code: 'price_overlap', detail: 'That price overlaps an existing effective period.' }, 409),
    })
    const user = userEvent.setup()
    open()
    await settle()
    await user.click(screen.getByRole('button', { name: 'Edit Wound dressing' }))
    const drawer = await screen.findByTestId('price-drawer')
    expect(await within(drawer).findByText('₹150.00')).toBeInTheDocument()
    await user.type(within(drawer).getByLabelText('Amount (rupees)'), '180')
    await user.click(within(drawer).getByRole('button', { name: 'Save price' }))
    expect(await screen.findAllByText('That price overlaps an existing effective period.')).toHaveLength(2)
    expect(calls.find((call) => call.method === 'POST' && call.path === '/api/v1/price-lists/items')!.body).toMatchObject({
      serviceItemId: DRESS,
      unitPricePaise: 18000,
    })
  })

  it('deactivates a service', async () => {
    const calls = routes()
    const user = userEvent.setup()
    open()
    await settle()
    await user.click(screen.getByRole('button', { name: 'Deactivate Wound dressing' }))
    expect(await screen.findByText(/Wound dressing is now inactive/)).toBeInTheDocument()
    expect(calls.find((call) => call.method === 'POST' && call.path === '/api/v1/service-items')!.body).toEqual({ id: DRESS, isActive: false })
  })

  it('previews a CSV, keeps overlapping rows out, and imports the ready ones in paise', async () => {
    const calls = routes({
      'POST /api/v1/price-lists/import': (_u, init) => {
        const body = JSON.parse(String(init.body)) as { dryRun: boolean; rows: { clientIndex: number; code: string; unitPricePaise: number }[] }
        return json({
          dryRun: body.dryRun,
          rows: body.rows.map((row) => ({
            clientIndex: row.clientIndex,
            code: row.code,
            name: row.code,
            status: row.code === 'CONSULT' ? 'price_overlap' : 'ready',
            detail: row.code === 'CONSULT' ? 'That price overlaps an existing effective period.' : null,
            item: 'existing',
            unitPricePaise: row.unitPricePaise,
          })),
        })
      },
    })
    const user = userEvent.setup()
    open()
    await screen.findAllByTestId('service-item-row')
    const file = new File(
      ['code,name,category,sac,rupees,effective_from,effective_to,branch_code\nCONSULT,OP consultation,consultation,9993,600,2026-04-01,,\nDRESS,Wound dressing,procedure,9993,180,2026-05-01,,\n'],
      'prices.csv',
      { type: 'text/csv' },
    )
    await user.upload(screen.getByLabelText('CSV file'), file)
    expect(await screen.findByText('Some rows overlap an existing effective period and will not be imported.')).toBeInTheDocument()
    expect(screen.getByText('That price overlaps an existing effective period.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Import 1 ready price' }))
    await screen.findByText('Imported 1 price. 1 overlapping period was left unchanged.')
    const posted = calls.filter((call) => call.path === '/api/v1/price-lists/import')
    expect(posted[0]!.body).toMatchObject({ dryRun: true })
    expect(posted[1]!.body).toEqual({
      dryRun: false,
      rows: [{ clientIndex: 1, code: 'DRESS', name: 'Wound dressing', category: 'procedure', sac: '9993', unitPricePaise: 18000, effectiveFrom: '2026-05-01' }],
    })
  })

  it('previews a copy onto a branch and then writes it', async () => {
    const calls = routes({
      'POST /api/v1/price-lists/copy': (_u, init) => {
        const body = JSON.parse(String(init.body)) as { dryRun?: boolean; branchId: string; effectiveFrom: string }
        return json({
          dryRun: body.dryRun === true,
          priceListId: body.dryRun ? null : 'branch-list',
          copied: 2,
          conflicts: [{ code: 'CONSULT', name: 'OP consultation', practitionerId: null, reason: 'price_overlap' }],
        })
      },
    })
    const user = userEvent.setup()
    open()
    await screen.findByRole('option', { name: 'Standard · Hospital' })
    await user.selectOptions(screen.getByLabelText('Copy to branch'), ALPHA_MAIN)
    await user.click(screen.getByRole('button', { name: 'Preview copy' }))
    expect(await screen.findByText(/2 rates will copy/)).toBeInTheDocument()
    expect(screen.getByText(/1 overlap and will be skipped: CONSULT/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Copy prices' }))
    expect(await screen.findByText(/Copied 2 rates to Alpha Main/)).toBeInTheDocument()
    const posted = calls.filter((call) => call.path === '/api/v1/price-lists/copy')
    expect(posted.map((call) => (call.body as { dryRun?: boolean }).dryRun)).toEqual([true, false])
    expect(posted[1]!.body).toMatchObject({ sourcePriceListId: LIST, branchId: ALPHA_MAIN, effectiveFrom: localToday() })
  })

  it('is hidden from a receptionist', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meWithRoles(['receptionist'])), 'GET /health/live': () => json({ status: 'Healthy' }) })
    open()
    expect(await screen.findByTestId('forbidden')).toHaveTextContent(/does not include access/i)
    expect(screen.queryByRole('link', { name: 'Price list' })).not.toBeInTheDocument()
  })
})
