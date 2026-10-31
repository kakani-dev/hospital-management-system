import { z } from 'zod'
import { isIanaZone } from '../admin/adminSchemas'

const zone = z
  .string()
  .trim()
  .min(1, { error: 'Choose the hospital time zone' })
  .refine(isIanaZone, { error: 'Use an IANA time zone, e.g. Asia/Kolkata' })

export const hospitalSignupSchema = z.object({
  hospitalName: z.string().trim().min(2, { error: 'Hospital name is required' }).max(120, { error: 'Max 120 characters' }),
  timeZone: zone,
  contactName: z.string().trim().min(2, { error: 'Your name is required' }).max(120, { error: 'Max 120 characters' }),
  contactEmail: z.string().trim().max(254).pipe(z.email({ error: 'Enter a valid email' })),
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9][0-9 ()-]{6,19}$/, { error: '7-20 digits; spaces, brackets and dashes allowed; may start with +' }),
  city: z.string().trim().min(2, { error: 'City is required' }).max(80, { error: 'Max 80 characters' }),
  website: z.string().optional(),
})
export type HospitalSignupValues = z.infer<typeof hospitalSignupSchema>

export const tenantCodeSchema = z
  .string()
  .trim()
  .regex(/^[a-z0-9][a-z0-9-]{1,39}$/, { error: '2-40 lowercase letters, digits or hyphens' })

export const createTenantSchema = z.object({
  name: z.string().trim().min(2, { error: 'Hospital name is required' }).max(120, { error: 'Max 120 characters' }),
  code: tenantCodeSchema,
  timeZone: zone,
  adminEmail: z.email({ error: 'Enter the first admin’s email' }).max(254),
  branches: z
    .array(z.object({ name: z.string().trim().min(1, { error: 'Branch name is required' }).max(120, { error: 'Max 120 characters' }), address: z.string().trim().max(300) }))
    .min(1, { error: 'Add at least one branch' })
    .max(20, { error: 'Up to 20 branches' })
    .refine((b) => new Set(b.map((x) => x.name.trim().toLowerCase())).size === b.length, { error: 'Branch names must be unique' }),
})
export type CreateTenantValues = z.infer<typeof createTenantSchema>

export const reasonSchema = z.object({ reason: z.string().trim().min(3, { error: 'Give a reason (at least 3 characters)' }).max(500) })
export type ReasonValues = z.infer<typeof reasonSchema>
