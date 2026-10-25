import { z } from 'zod'
import { ROLES } from '../../lib/api/types'

export const isIanaZone = (tz: string) => {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz })
    return tz.length > 0
  } catch {
    return false
  }
}

const gstinField = z
  .string()
  .trim()
  .toUpperCase()
  .refine((value) => value === '' || /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(value), {
    error: 'Enter a 15-character GSTIN',
  })

export const branchSchema = z
  .object({
    code: z
      .string()
      .trim()
      .regex(/^[a-z0-9][a-z0-9-]{1,39}$/, { error: '2-40 lowercase letters, digits or hyphens' }),
    name: z.string().trim().min(1, { error: 'Name is required' }).max(120, { error: 'Max 120 characters' }),
    /** true (the form's default): no override, the branch follows the hospital zone. */
    useHospitalZone: z.boolean().optional(),
    timezone: z.string().trim(),
    address: z.string().trim().max(300, { error: 'Max 300 characters' }).optional(),
    gstin: gstinField.optional(),
    legalName: z.string().trim().max(200, { error: 'Max 200 characters' }).optional(),
  })
  .refine((v) => v.useHospitalZone === true || isIanaZone(v.timezone), {
    path: ['timezone'],
    error: 'Use an IANA time zone, e.g. Asia/Kolkata',
  })
export type BranchFormValues = z.infer<typeof branchSchema>

export const TENANT_ADMIN_BRANCH_ERROR = 'Tenant admins are hospital-wide: choose All branches'

export const memberSchema = z
  .object({
    email: z.email({ error: 'Enter a valid email address' }),
    role: z.enum(ROLES),
    branchId: z.union([z.literal(''), z.uuid()]),
  })
  // Mirrors the API (400) and DB CHECK (role <> 'tenant_admin' or branch_id is null).
  .refine((v) => v.role !== 'tenant_admin' || v.branchId === '', { path: ['branchId'], error: TENANT_ADMIN_BRANCH_ERROR })
export type MemberFormValues = z.infer<typeof memberSchema>

/** Edit an existing branch: name plus "follow the hospital zone" or an explicit override. */
export const branchEditSchema = z
  .object({
    name: z.string().trim().min(1, { error: 'Name is required' }).max(120, { error: 'Max 120 characters' }),
    useHospitalZone: z.boolean(),
    timezone: z.string().trim(),
    address: z.string().trim().max(300, { error: 'Max 300 characters' }).optional(),
    gstin: gstinField.optional(),
    legalName: z.string().trim().max(200, { error: 'Max 200 characters' }).optional(),
  })
  .refine((v) => v.useHospitalZone || isIanaZone(v.timezone), { path: ['timezone'], error: 'Use an IANA time zone, e.g. Asia/Kolkata' })
export type BranchEditValues = z.infer<typeof branchEditSchema>

/** The hospital's own zone is required (branches without an override follow it). */
export const hospitalSchema = z.object({
  name: z.string().trim().min(1, { error: 'Name is required' }).max(200, { error: 'Max 200 characters' }),
  timeZone: z
    .string()
    .trim()
    .refine(isIanaZone, { error: 'Use an IANA time zone, e.g. Asia/Kolkata' }),
  defaultCountryCode: z
    .string()
    .trim()
    .refine((value) => value === '' || /^\+[1-9]\d{0,2}$/.test(value), { error: 'Use a calling code like +91' }),
})
export type HospitalValues = z.infer<typeof hospitalSchema>

export const practitionerSchema = z.object({
  displayName: z.string().trim().min(1, { error: 'Name is required' }).max(200, { error: 'Max 200 characters' }),
  specialty: z.string().trim().max(200, { error: 'Max 200 characters' }),
  /** '' = not linked to a staff account. */
  userId: z.union([z.literal(''), z.guid()]),
  registrationNumber: z.string().trim().max(30, { error: 'Max 30 characters' }),
  councilName: z.string().trim().max(120, { error: 'Max 120 characters' }),
  qualifications: z.string().trim().max(200, { error: 'Max 200 characters' }),
  departmentId: z.string(),
  phone: z.string().trim().max(20, { error: 'Max 20 characters' }),
  email: z.string().trim().max(254, { error: 'Max 254 characters' }),
})
export type PractitionerValues = z.infer<typeof practitionerSchema>

const HH_MM = /^([01]\d|2[0-3]):[0-5]\d$/
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

/** Weekly working hours in branch-local wall-clock time. */
export const scheduleSchema = z
  .object({
    practitionerId: z.guid({ error: 'Choose a practitioner' }),
    weekday: z.coerce.number<string>().int().min(1).max(7),
    startTime: z.string().regex(HH_MM, { error: 'Use HH:mm' }),
    endTime: z.string().regex(HH_MM, { error: 'Use HH:mm' }),
    slotMinutes: z.coerce
      .number<string>({ error: 'Enter minutes' })
      .int({ error: 'Whole minutes' })
      .min(5, { error: '5 to 240 minutes' })
      .max(240, { error: '5 to 240 minutes' }),
    validFrom: z.string().regex(ISO_DATE, { error: 'Choose a start date' }),
    validTo: z.union([z.literal(''), z.string().regex(ISO_DATE)]),
  })
  .refine((v) => v.endTime > v.startTime, { path: ['endTime'], error: 'End must be after start' })
  .refine((v) => !v.validTo || v.validTo >= v.validFrom, { path: ['validTo'], error: 'Must be on or after the start date' })
export type ScheduleFormInput = z.input<typeof scheduleSchema>
export type ScheduleValues = z.output<typeof scheduleSchema>
