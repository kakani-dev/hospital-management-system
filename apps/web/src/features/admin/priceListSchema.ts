import { z } from 'zod'
import { parseRupeesToPaise } from '../billing/money'
import { SERVICE_CATEGORIES } from './priceCsv'

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const serviceItemSchema = z.object({
  name: z.string().trim().min(1, { error: 'Name is required' }).max(160, { error: 'Max 160 characters' }),
  category: z.enum(SERVICE_CATEGORIES),
  customCode: z.string().trim().max(40, { error: 'Max 40 characters' }),
  taxCodeId: z.string().trim(),
}).refine((v) => v.taxCodeId === '' || UUID.test(v.taxCodeId), { path: ['taxCodeId'], error: 'Choose a tax code' })
export type ServiceItemValues = z.infer<typeof serviceItemSchema>

export const serviceItemEditSchema = z.object({
  name: z.string().trim().min(1, { error: 'Name is required' }).max(160, { error: 'Max 160 characters' }),
  category: z.enum(SERVICE_CATEGORIES),
  taxCodeId: z.guid({ error: 'Choose a tax code' }),
})
export type ServiceItemEditValues = z.infer<typeof serviceItemEditSchema>

export const priceEntrySchema = z
  .object({
    scope: z.enum(['tenant', 'branch', 'practitioner']),
    branchId: z.string(),
    practitionerId: z.string(),
    rupees: z.string().trim().min(1, { error: 'Enter an amount in rupees' }),
    effectiveFrom: z.string().regex(ISO_DATE, { error: 'Use a date' }),
    effectiveTo: z.string(),
  })
  .refine((v) => parseRupeesToPaise(v.rupees) !== null, { path: ['rupees'], error: 'Use rupees, with at most two decimals' })
  .refine((v) => v.effectiveTo === '' || (ISO_DATE.test(v.effectiveTo) && v.effectiveTo > v.effectiveFrom), {
    path: ['effectiveTo'],
    error: 'End date must be after the start',
  })
  .refine((v) => v.scope !== 'branch' || UUID.test(v.branchId), { path: ['branchId'], error: 'Choose a branch' })
  .refine((v) => v.scope !== 'practitioner' || UUID.test(v.practitionerId), { path: ['practitionerId'], error: 'Choose a practitioner' })
  .refine((v) => v.scope !== 'practitioner' || v.branchId === '' || UUID.test(v.branchId), {
    path: ['branchId'],
    error: 'Choose a branch',
  })
export type PriceEntryValues = z.infer<typeof priceEntrySchema>
