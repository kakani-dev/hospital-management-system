import { z } from 'zod'
import { SEXES, type Sex, type WhatsappInput, type RegistrationDetails } from '../../lib/api/types'
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

/** Same limit as the API (CreatePatientValidator.AllergiesMaxLength). */
export const ALLERGIES_MAX = 500

const dText = (max: number) => z.string().trim().max(max, { error: `Max ${max} characters` }).optional()
export const BLOOD_GROUPS = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'] as const
export const REFERRAL_SOURCES = ['walk_in', 'self', 'doctor', 'hospital', 'health_camp', 'insurance', 'corporate', 'other'] as const
export const REFERRAL_LABELS: Record<(typeof REFERRAL_SOURCES)[number], string> = {
  walk_in: 'Walk-in', self: 'Self / family', doctor: 'Doctor referral', hospital: 'Other hospital',
  health_camp: 'Health camp', insurance: 'Insurance / TPA', corporate: 'Corporate', other: 'Other',
}
export const PIN_ERROR = 'PIN code is 6 digits and does not start with 0'
const detailsSchema = z.object({
  addressLine: dText(200), city: dText(100), district: dText(100), state: dText(100),
  pinCode: z.string().optional().refine((v) => !v?.trim() || /^[1-9]\d{5}$/.test(v.replace(/\s/g, '')), { error: PIN_ERROR }),
  emergencyContactName: dText(150), emergencyContactRelation: dText(50),
  emergencyContactPhone: optionalText(32).optional().refine((v) => !v || PHONE_SHAPE.test(v), { error: 'Enter a valid phone number, e.g. 98765 43210' }),
  guardianName: dText(150), guardianRelation: dText(50),
  bloodGroup: z.string().optional(), referralSource: z.string().optional(), referredBy: dText(150),
})
export type DetailsFormValues = z.infer<typeof detailsSchema>
export const EMPTY_DETAILS: Required<{ [K in keyof DetailsFormValues]: string }> = {
  addressLine: '', city: '', district: '', state: '', pinCode: '', emergencyContactName: '', emergencyContactRelation: '',
  emergencyContactPhone: '', guardianName: '', guardianRelation: '', bloodGroup: '', referralSource: 'walk_in', referredBy: '',
}

/** Form → API: blanks become null; the whole object is null when nothing beyond the walk-in default was entered. */
export function toDetailsInput(d: DetailsFormValues | undefined): RegistrationDetails | null {
  if (!d) return null
  const out: RegistrationDetails = {}
  let any = false
  for (const [k, v] of Object.entries(d)) {
    const t = typeof v === 'string' ? v.trim() : ''
    ;(out as Record<string, string | null>)[k] = t || null
    if (t && !(k === 'referralSource' && t === 'walk_in')) any = true
  }
  return any ? out : null
}

/** API → form (edit). */
export function fromDetails(d: RegistrationDetails | null | undefined) {
  const out = { ...EMPTY_DETAILS }
  for (const k of Object.keys(out) as (keyof typeof out)[]) out[k] = (d?.[k] as string | null | undefined) ?? (k === 'referralSource' ? 'walk_in' : '')
  return out
}

export function createPatientSchema(getTimeZone: TimeZoneGetter = () => undefined) {
  return z.object({
  firstName: z.string().trim().min(1, { error: 'First name is required' }).max(100, { error: 'Max 100 characters' }),
  /** #190: optional — many patients have a single name. */
  lastName: z.string().trim().max(100, { error: 'Max 100 characters' }),
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
  /** #275: free text shown to the pharmacist at dispense. Blank = not recorded. */
  knownAllergies: z.string().trim().max(ALLERGIES_MAX, { error: `Keep allergies to ${ALLERGIES_MAX} characters` }).optional(),
  /** #58: optional "More details"; the server applies the tenant's required rules. */
  details: detailsSchema.optional(),
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

export const MAX_AGE_YEARS = 120
export const SEX_REQUIRED_ERROR = 'Choose the sex (Unknown is allowed)'
export const DOB_OR_AGE_ERROR = 'Enter a date of birth or an age'
export const AGE_ERROR = `Age must be a whole number from 0 to ${MAX_AGE_YEARS}`
export const PHONE_REQUIRED_ERROR = 'Mobile number is required, or tick "Patient has no mobile" and give a reason'
export const NO_PHONE_REASON_ERROR = 'Give a reason (3 to 200 characters)'

/**
 * #190: a NEW registration (not an edit) must have the sex chosen (no silent default), a date of
 * birth or an age (the server estimates the DOB and flags it), and a mobile number or a reason
 * why there is none. Mirrors CreatePatientValidator.ValidateRegistration.
 */
export function createRegisterPatientSchema(getTimeZone: TimeZoneGetter = () => undefined) {
  return createPatientSchema(getTimeZone)
    .extend({
      sex: z.union([z.enum(SEXES), z.literal('')]),
      ageYears: z.string().trim(),
      noPhone: z.boolean(),
      noPhoneReason: z.string().trim(),
    })
    .superRefine((v, ctx) => {
      if (v.sex === '') ctx.addIssue({ code: 'custom', path: ['sex'], message: SEX_REQUIRED_ERROR })
      if (v.ageYears !== '' && !(/^\d{1,3}$/.test(v.ageYears) && Number(v.ageYears) <= MAX_AGE_YEARS)) {
        ctx.addIssue({ code: 'custom', path: ['ageYears'], message: AGE_ERROR })
      } else if (v.dateOfBirth === '' && v.ageYears === '') {
        ctx.addIssue({ code: 'custom', path: ['dateOfBirth'], message: DOB_OR_AGE_ERROR })
      }
      if (v.noPhone) {
        if (v.noPhoneReason.length < 3 || v.noPhoneReason.length > 200) {
          ctx.addIssue({ code: 'custom', path: ['noPhoneReason'], message: NO_PHONE_REASON_ERROR })
        }
      } else if (v.phone.trim() === '') {
        ctx.addIssue({ code: 'custom', path: ['phone'], message: PHONE_REQUIRED_ERROR })
      }
    })
}

export const registerPatientSchema = createRegisterPatientSchema()
export type RegisterPatientFormValues = z.infer<typeof registerPatientSchema>

export function toCreatePatientRequest(v: RegisterPatientFormValues, duplicateOverrideReason?: string) {
  const reason = duplicateOverrideReason?.trim()
  const noPhone = v.noPhone && !v.phone.trim()
  return {
    firstName: v.firstName.trim(),
    lastName: v.lastName.trim(),
    dateOfBirth: v.dateOfBirth || null,
    ...(!v.dateOfBirth && v.ageYears.trim() ? { ageYears: Number(v.ageYears.trim()) } : {}),
    sex: v.sex as Sex,
    registeredBranchId: v.registeredBranchId,
    phone: noPhone ? null : v.phone.trim() || null,
    ...(noPhone ? { noPhoneReason: v.noPhoneReason.trim() } : {}),
    email: v.email || null,
    whatsapp: toWhatsappInput(v),
    abhaNumber: toAbha(v.abhaNumber ?? ''),
    ...(v.knownAllergies?.trim() ? { knownAllergies: v.knownAllergies.trim() } : {}),
    ...(toDetailsInput(v.details) ? { details: toDetailsInput(v.details)! } : {}),
    ...(reason ? { duplicateOverrideReason: reason } : {}),
  }
}

/** Edit form: same fields (the MRN is server-generated and never part of either form). */
export const createPatientEditSchema = (getTimeZone: TimeZoneGetter = () => undefined) => createPatientSchema(getTimeZone)
export const patientEditSchema = createPatientEditSchema()
export type PatientEditValues = z.infer<typeof patientEditSchema>

/** Full replacement of the editable fields; cleared optional fields are sent as null. */
export function toUpdatePatientRequest(v: PatientEditValues, duplicateOverrideReason?: string) {
  const reason = duplicateOverrideReason?.trim()
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
    // Cleared = not recorded (null); the pharmacist then sees a warning.
    knownAllergies: v.knownAllergies?.trim() || null,
    details: toDetailsInput(v.details),
    ...(reason ? { duplicateOverrideReason: reason } : {}),
  }
}

/** Whole years from a yyyy-mm-dd DOB (birthday counts), else the typed age, else null. */
export function ageFrom(dob: string, typedAge: string, today: string): number | null {
  if (/^\d{4}-\d{2}-\d{2}$/.test(dob)) {
    const [y, m, d] = dob.split('-').map(Number) as [number, number, number]
    const [ty, tm, td] = today.split('-').map(Number) as [number, number, number]
    return ty - y - (tm < m || (tm === m && td < d) ? 1 : 0)
  }
  const n = Number(typedAge.trim())
  return typedAge.trim() && Number.isFinite(n) ? n : null
}
