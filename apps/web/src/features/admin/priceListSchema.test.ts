import { describe, expect, it } from 'vitest'
import { priceEntrySchema, serviceItemSchema } from './priceListSchema'

const TAX = '11111111-0000-4000-8000-0000000000aa'
const BRANCH = 'a1111111-0000-4000-8000-000000000001'

describe('serviceItemSchema', () => {
  it('accepts a name and category, and an optional custom code', () => {
    expect(serviceItemSchema.safeParse({ name: 'Dressing', category: 'procedure', customCode: '', taxCodeId: '' }).success).toBe(true)
    expect(serviceItemSchema.safeParse({ name: 'Dressing', category: 'procedure', customCode: 'LEGACY', taxCodeId: TAX }).success).toBe(true)
    expect(serviceItemSchema.safeParse({ name: '', category: 'procedure', customCode: '', taxCodeId: '' }).success).toBe(false)
    expect(serviceItemSchema.safeParse({ name: 'Dressing', category: 'procedure', customCode: 'x'.repeat(41), taxCodeId: '' }).success).toBe(false)
  })
})

describe('priceEntrySchema', () => {
  const base = { scope: 'tenant' as const, branchId: '', practitionerId: '', rupees: '150', effectiveFrom: '2026-04-01', effectiveTo: '' }

  it('accepts a hospital rate in rupees', () => {
    expect(priceEntrySchema.safeParse(base).success).toBe(true)
    expect(priceEntrySchema.safeParse({ ...base, rupees: '1,500.50' }).success).toBe(true)
  })

  it('rejects extra decimals, a branch with no branch, and an end date that is not later', () => {
    expect(priceEntrySchema.safeParse({ ...base, rupees: '10.555' }).success).toBe(false)
    expect(priceEntrySchema.safeParse({ ...base, scope: 'branch', branchId: '' }).success).toBe(false)
    expect(priceEntrySchema.safeParse({ ...base, scope: 'branch', branchId: BRANCH }).success).toBe(true)
    expect(priceEntrySchema.safeParse({ ...base, effectiveTo: '2026-04-01' }).success).toBe(false)
    expect(priceEntrySchema.safeParse({ ...base, effectiveTo: '2026-05-01' }).success).toBe(true)
  })
})
