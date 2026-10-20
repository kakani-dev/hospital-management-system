import { z } from 'zod'
import { SEXES, type WhatsappInput } from '../../lib/api/types'
import { latestToday, localToday } from '../../lib/dates'

/** Returns the IANA zone "today" is computed in; undefined = the workstation's zone. */
export type TimeZoneGetter = () => string | undefined

const optionalText = (max: number) => z.string().trim().max(max, { error: `Max ${max} characters` })

export const DOB_ERROR = 'Date of birth must be between 1900-01-01 and today'

/**
 * Mirrors CreatePatientValidator (API) and the patient.patients CHECK constraints (DB). The API
 * checks DOB ≤ today **in the registering branch's time zone**, so "today" comes from
 * `getTimeZone` (the selected branch), evaluated per validation — not the workstation's zone.
 */
/** "Today" in the branch zone; with no zone known yet, the latest date anywhere (the API re-checks). */
const todayIn = (timeZone: string | undefined) => (timeZone ? localToday(new Date(), timeZone) : latestToday())

export function createPatientSchema(getTimeZone: TimeZoneGetter = () => undefined) {
  return z.object({
  firstName: z.string().trim().min(1, { error: 'First name is required' }).max(100, { error: 'Max 100 characters' }),
  lastName: z.string().trim().min(1, { error: 'Last name is required' }).max(100, { error: 'Max 100 characters' }),
  dateOfBirth: z
    .string()
    .refine((v) => v === '' || (/^\d{4}-\d{2}-\d{2}$/.test(v) && v >= '1900-01-01' && v <= todayIn(getTimeZone())), {
      error: DOB_ERROR,
    }),
  sex: z.enum(SEXES),
  registeredBranchId: z.uuid({ error: 'Choose a branch' }),
  phone: optionalText(32).refine((v) => v === '' || PHONE_SHAPE.test(v), { error: PHONE_ERROR }),
  email: z.union([z.literal(''), z.email({ error: 'Enter a valid email address' })]),
  /** "Same as phone number" (checked by default). */
  whatsappSameAsPhone: z.boolean(),
  whatsappNumber: optionalText(32).refine((v) => v === '' || PHONE_SHAPE.test(v), { error: WHATSAPP_ERROR }),
  /** Optional ABHA number: 14 digits, spaces / dashes allowed while typing. */
  abhaNumber: z.string().trim().optional().refine((v) => !v || toAbha(v) !== null, { error: ABHA_ERROR }),
})
}

/**
 * Loose client-side shape check (digits with optional +, spaces, dashes, brackets; 7+ digits). The
 * server normalizes to E.164 with the hospital's calling code and is the authority.
 */
const PHONE_SHAPE = /^\+?[0-9()\s.-]*$/
export const PHONE_ERROR = 'Enter a valid phone number, e.g. 98765 43210 or +971 50 123 4567'
export const WHATSAPP_ERROR = 'Enter a valid WhatsApp number, e.g. 98765 43210 or +971 50 123 4567'

export const ABHA_ERROR = 'ABHA number must be 14 digits (XX-XXXX-XXXX-XXXX)'

/** ABHA number in its canonical XX-XXXX-XXXX-XXXX form, or null when it is not 14 digits (spaces / dashes ignored). */
export function toAbha(value: string): string | null {
  const digits = value.replace(/[\s-]/g, '')
  if (!/^\d{14}$/.test(digits)) return null
  return `${digits.slice(0, 2)}-${digits.slice(2, 6)}-${digits.slice(6, 10)}-${digits.slice(10)}`
}

/** The WhatsApp part of a create / update body from the form values. */
export function toWhatsappInput(v: Pick<PatientFormValues, 'phone' | 'whatsappSameAsPhone' | 'whatsappNumber'>): WhatsappInput | null {
  if (v.whatsappSameAsPhone) return v.phone.trim() ? { sameAsPhone: true } : null
  const number = v.whatsappNumber.trim()
  return number ? { sameAsPhone: false, number } : null
}

/** Schema without a branch context: DOB is only checked against the latest date anywhere. */
export const patientSchema = createPatientSchema()

export type PatientFormValues = z.infer<typeof patientSchema>

export function toCreatePatientRequest(v: PatientFormValues) {
  return {
    firstName: v.firstName.trim(),
    lastName: v.lastName.trim(),
    dateOfBirth: v.dateOfBirth || null,
    sex: v.sex,
    registeredBranchId: v.registeredBranchId,
    phone: v.phone.trim() || null,
    email: v.email || null,
    whatsapp: toWhatsappInput(v),
    abhaNumber: toAbha(v.abhaNumber ?? ''),
  }
}

/** Edit form: same fields (the MRN is server-generated and never part of either form). */
export const createPatientEditSchema = (getTimeZone: TimeZoneGetter = () => undefined) => createPatientSchema(getTimeZone)
export const patientEditSchema = createPatientEditSchema()
export type PatientEditValues = z.infer<typeof patientEditSchema>

/** Full replacement of the editable fields; cleared optional fields are sent as null. */
export function toUpdatePatientRequest(v: PatientEditValues) {
  return {
    firstName: v.firstName.trim(),
    lastName: v.lastName.trim(),
    dateOfBirth: v.dateOfBirth || null,
    sex: v.sex,
    registeredBranchId: v.registeredBranchId,
    phone: v.phone.trim() || null,
    email: v.email || null,
    whatsapp: toWhatsappInput(v),
    abhaNumber: toAbha(v.abhaNumber ?? ''),
  }
}
