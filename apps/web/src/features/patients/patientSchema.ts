import { z } from 'zod'
import { SEXES } from '../../lib/api/types'
import { localToday } from '../../lib/dates'

/** Returns the IANA zone "today" is computed in; undefined = the workstation's zone. */
export type TimeZoneGetter = () => string | undefined

const optionalText = (max: number) => z.string().trim().max(max, { error: `Max ${max} characters` })

export const DOB_ERROR = 'Date of birth must be between 1900-01-01 and today'

/**
 * Mirrors CreatePatientValidator (API) and the patient.patients CHECK constraints (DB). The API
 * checks DOB ≤ today **in the registering branch's time zone**, so "today" comes from
 * `getTimeZone` (the selected branch), evaluated per validation — not the workstation's zone.
 */
export function createPatientSchema(getTimeZone: TimeZoneGetter = () => undefined) {
  return z.object({
  mrn: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9-]{1,32}$/, { error: 'MRN is required: 1-32 letters, digits or hyphens' }),
  firstName: z.string().trim().min(1, { error: 'First name is required' }).max(100, { error: 'Max 100 characters' }),
  lastName: z.string().trim().min(1, { error: 'Last name is required' }).max(100, { error: 'Max 100 characters' }),
  dateOfBirth: z
    .string()
    .refine((v) => v === '' || (/^\d{4}-\d{2}-\d{2}$/.test(v) && v >= '1900-01-01' && v <= localToday(new Date(), getTimeZone())), {
      error: DOB_ERROR,
    }),
  sex: z.enum(SEXES),
  registeredBranchId: z.uuid({ error: 'Choose a branch' }),
  phone: optionalText(32),
  email: z.union([z.literal(''), z.email({ error: 'Enter a valid email address' })]),
})
}

/** Workstation-zone schema (kept for callers without a branch context). */
export const patientSchema = createPatientSchema()

export type PatientFormValues = z.infer<typeof patientSchema>

export function toCreatePatientRequest(v: PatientFormValues) {
  return {
    mrn: v.mrn.trim(),
    firstName: v.firstName.trim(),
    lastName: v.lastName.trim(),
    dateOfBirth: v.dateOfBirth || null,
    sex: v.sex,
    registeredBranchId: v.registeredBranchId,
    phone: v.phone.trim() || null,
    email: v.email || null,
  }
}

/** Edit form: MRN is immutable after registration (PATCH never sends it). */
export const createPatientEditSchema = (getTimeZone: TimeZoneGetter = () => undefined) => createPatientSchema(getTimeZone).omit({ mrn: true })
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
  }
}
