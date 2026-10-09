import { z } from 'zod'
import { SEXES } from '../../lib/api/types'
import { localToday } from '../../lib/dates'

/** "Today" in local (branch workstation) time — evaluated per validation, not at import. */
const today = () => localToday()
const optionalText = (max: number) => z.string().trim().max(max, { error: `Max ${max} characters` })

/** Mirrors CreatePatientValidator (API) and the patient.patients CHECK constraints (DB). */
export const patientSchema = z.object({
  mrn: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9-]{1,32}$/, { error: 'MRN is required: 1-32 letters, digits or hyphens' }),
  firstName: z.string().trim().min(1, { error: 'First name is required' }).max(100, { error: 'Max 100 characters' }),
  lastName: z.string().trim().min(1, { error: 'Last name is required' }).max(100, { error: 'Max 100 characters' }),
  dateOfBirth: z
    .string()
    .refine((v) => v === '' || (/^\d{4}-\d{2}-\d{2}$/.test(v) && v >= '1900-01-01' && v <= today()), {
      error: 'Date of birth must be between 1900-01-01 and today',
    }),
  sex: z.enum(SEXES),
  registeredBranchId: z.uuid({ error: 'Choose a branch' }),
  phone: optionalText(32),
  email: z.union([z.literal(''), z.email({ error: 'Enter a valid email address' })]),
})

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
export const patientEditSchema = patientSchema.omit({ mrn: true })
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
