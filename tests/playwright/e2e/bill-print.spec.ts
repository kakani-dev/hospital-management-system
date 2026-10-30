import { expect, test, type APIRequestContext } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * #76 / REG-037 printed bill and receipt against the real API: numbering, GSTIN and the GST breakup.
 * Fixtures go through the API: a Zz- patient, a fresh taxable service with a fresh price, two bills
 * finalized in a row (numbers must be distinct, same prefix, increasing) and a UPI payment.
 * Expected values come from the API, never from literals.
 */

interface Bill {
  id: string; billNo: string | null; totalPaise: number; taxPaise?: number
  cgstPaise: number | null; sgstPaise: number | null; igstPaise: number | null
  supplier: { gstin: string | null; name: string | null } | null
  lines: { name: string; sacHsnCode: string | null; taxPaise: number; netPaise: number }[]
}
interface TaxCode { id: string; rateBp: number; isExempt: boolean; sacHsnCode: string }

const rupees = (paise: number) => new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(paise / 100)
const today = () => new Date().toISOString().slice(0, 10)

async function taxableService(request: APIRequestContext, h: Record<string, string>) {
  const taxes = (await (await request.get('/api/v1/service-items/tax-codes', { headers: h })).json()) as TaxCode[]
  const tax = taxes.filter((t) => !t.isExempt && t.rateBp > 0).sort((a, b) => a.rateBp - b.rateBp)[0]
  test.skip(!tax, 'no taxable tax code configured')
  const name = `Zz-E2E ${unique('Print')}`
  const item = await request.post('/api/v1/service-items', { headers: h, data: { name, category: 'procedure', taxCodeId: tax!.id } })
  expect(item.status()).toBe(200)
  const serviceItemId = ((await item.json()) as { id: string }).id
  const lists = (await (await request.get('/api/v1/price-lists', { headers: h })).json()) as { id: string; name: string; branchId: string | null }[]
  const standard = lists.find((l) => l.name === 'Standard' && l.branchId === null)!
  const price = await request.post('/api/v1/price-lists/items', {
    headers: h, data: { priceListId: standard.id, serviceItemId, unitPricePaise: 11800, effectiveFrom: today() },
  })
  expect(price.status()).toBe(200)
  return { serviceItemId, name, tax: tax! }
}

async function finalizedBill(request: APIRequestContext, h: Record<string, string>, serviceItemId: string) {
  const patient = await request.post('/api/v1/patients', {
    headers: h, data: { firstName: 'Print', lastName: `Zz-E2E-${unique('Pt')}`, registeredBranchId: ids.alphaMain, sex: 'male', ageYears: 41, noPhoneReason: 'test fixture' },
  })
  expect(patient.ok()).toBeTruthy()
  const opened = await request.post('/api/v1/accounts', { headers: h, data: { patientId: ((await patient.json()) as { id: string }).id, branchId: ids.alphaMain } })
  expect(opened.status()).toBe(200)
  const { id: billId, accountId } = (await opened.json()) as { id: string; accountId: string }
  expect((await request.post(`/api/v1/bills/${billId}/lines`, { headers: h, data: { serviceItemId } })).status()).toBe(200)
  const fin = await request.post(`/api/v1/bills/${billId}/finalize`, { headers: h, data: {} })
  expect(fin.status()).toBe(200)
  const bill = (await (await request.get(`/api/v1/bills/${billId}`, { headers: h })).json()) as Bill
  return { bill, accountId }
}

test('printed bill and receipt carry numbering, GSTIN and the GST breakup from the server', async ({ page, request }) => {
  const h = bearer(await tokenFor(request, users.alphaAdmin))
  const svc = await taxableService(request, h)
  const first = await finalizedBill(request, h, svc.serviceItemId)
  const second = await finalizedBill(request, h, svc.serviceItemId)

  // Numbering: both numbered, same prefix, distinct and increasing.
  const a = first.bill.billNo!, b = second.bill.billNo!
  expect(a).toBeTruthy()
  expect(b).toBeTruthy()
  expect(b).not.toBe(a)
  expect(a.slice(0, 5)).toBe(b.slice(0, 5))
  expect(b > a).toBeTruthy()

  // Tax breakup adds up: intra-state CGST + SGST (or IGST) equals the line tax, and it is not zero.
  const lineTax = second.bill.lines.reduce((s, l) => s + l.taxPaise, 0)
  expect(lineTax).toBeGreaterThan(0)
  expect((second.bill.cgstPaise ?? 0) + (second.bill.sgstPaise ?? 0) + (second.bill.igstPaise ?? 0)).toBe(lineTax)

  const profile = (await (await request.get(`/api/v1/price-lists/branches/${ids.alphaMain}/profile`, { headers: h })).json()) as { gstin: string | null }
  expect(second.bill.supplier?.gstin ?? null).toBe(profile.gstin ?? null)

  await signIn(page, users.alphaAdmin)
  await page.goto(`/billing/bills/${second.bill.id}`)
  await expect(page.getByTestId('billing-bill-detail-number')).toHaveText(b)
  await expect(page.getByTestId('bill-gstin')).toHaveText(`GSTIN ${profile.gstin ?? 'Not set'}`)
  await expect(page.getByTestId('gst-components')).toHaveText(
    `CGST ${rupees(second.bill.cgstPaise ?? 0)} · SGST ${rupees(second.bill.sgstPaise ?? 0)} · IGST ${rupees(second.bill.igstPaise ?? 0)}`,
  )
  await expect(page.getByTestId('bill-detail')).toContainText(`SAC ${svc.tax.sacHsnCode}`)
  await expect(page.getByTestId('bill-detail')).toContainText(svc.name)

  const pay = await request.post('/api/v1/payments', {
    headers: { ...h, 'Idempotency-Key': crypto.randomUUID() },
    data: { accountId: second.accountId, kind: 'payment', tenders: [{ mode: 'upi', amountPaise: second.bill.totalPaise }], allocations: [{ billId: second.bill.id, amountPaise: second.bill.totalPaise }] },
  })
  expect(pay.status()).toBe(200)
  const receipt = (await pay.json()) as { id: string; receiptNo: string | null }

  await page.goto(`/billing/receipts/${receipt.id}`)
  await expect(page.getByTestId('billing-receipt-no')).toHaveText(receipt.receiptNo ?? receipt.id)
  await expect(page.getByTestId('billing-receipt-bill-no')).toHaveText(b)
  if (profile.gstin) await expect(page.getByTestId('billing-receipt-gstin')).toHaveText(`GSTIN ${profile.gstin}`)
  else await expect(page.getByTestId('billing-receipt-gstin')).toHaveCount(0)
  await expect(page.getByTestId('billing-receipt-lines')).toContainText(svc.name)
  await expect(page.getByTestId('billing-receipt-bill-total')).toContainText(rupees(second.bill.totalPaise))
  await expect(page.getByTestId('billing-receipt-amount')).toContainText(rupees(second.bill.totalPaise))
  await expect(page.getByTestId('billing-receipt-tenders')).toContainText('Mode: UPI')
})
