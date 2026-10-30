import { describe, expect, it } from 'vitest'
import { registerPatientSchema as patientSchema, toCreatePatientRequest } from './patientSchema'

const valid = {
  firstName: 'Asha',
  lastName: 'Synthetic',
  dateOfBirth: '1990-01-01',
  sex: 'female' as const,
  registeredBranchId: 'a1111111-0000-4000-8000-000000000001',
  phone: '',
  email: '',
  whatsappSameAsPhone: true,
  whatsappNumber: '',
  ageYears: '',
  noPhone: true,
  noPhoneReason: 'Patient has no phone',
}

describe('patientSchema', () => {
  it('accepts a valid patient and normalises optional fields to null', () => {
    const parsed = patientSchema.parse(valid)
    expect(toCreatePatientRequest(parsed)).toMatchObject({ phone: null, email: null, dateOfBirth: '1990-01-01', whatsapp: null })
    expect(toCreatePatientRequest(parsed)).not.toHaveProperty('mrn')
  })

  it('maps the WhatsApp section to { sameAsPhone, number } (or null for none)', () => {
    const withPhone = { ...valid, phone: '98450 00001' }
    expect(toCreatePatientRequest(patientSchema.parse(withPhone)).whatsapp).toEqual({ sameAsPhone: true })
    expect(toCreatePatientRequest(patientSchema.parse({ ...withPhone, whatsappSameAsPhone: false, whatsappNumber: ' +971 50 123 4567 ' })).whatsapp)
      .toEqual({ sameAsPhone: false, number: '+971 50 123 4567' })
    expect(toCreatePatientRequest(patientSchema.parse({ ...withPhone, whatsappSameAsPhone: false })).whatsapp).toBeNull()
    // "same" with no phone means no WhatsApp (nothing to flag)
    expect(toCreatePatientRequest(patientSchema.parse(valid)).whatsapp).toBeNull()
  })

  it.each([
    ['phone', 'call me'],
    ['whatsappNumber', 'not a number'],
    ['firstName', '  '],
    ['dateOfBirth', '1899-12-31'],
    ['dateOfBirth', '2999-01-01'],
    ['registeredBranchId', ''],
    ['email', 'not-an-email'],
  ])('rejects invalid %s (%s)', (field, value) => {
    expect(patientSchema.safeParse({ ...valid, [field]: value }).success).toBe(false)
  })
})

describe('ABHA number', () => {
  it('formats 14 digits as XX-XXXX-XXXX-XXXX and rejects anything else', async () => {
    const { toAbha, patientSchema } = await import('./patientSchema')
    expect(toAbha('12345678901234')).toBe('12-3456-7890-1234')
    expect(toAbha('12 3456 7890 1234')).toBe('12-3456-7890-1234')
    expect(toAbha('12-3456-7890-123')).toBeNull()
    expect(toAbha('12-3456-7890-12a4')).toBeNull()
    const base = {
      firstName: 'A', lastName: 'B', dateOfBirth: '', sex: 'unknown', registeredBranchId: '11111111-1111-4111-8111-111111111111',
      phone: '', email: '', whatsappSameAsPhone: true, whatsappNumber: '',
    }
    expect(patientSchema.safeParse({ ...base, abhaNumber: '' }).success).toBe(true)
    expect(patientSchema.safeParse({ ...base, abhaNumber: '1234' }).success).toBe(false)
    expect(patientSchema.safeParse({ ...base, abhaNumber: '12-3456-7890-1234' }).success).toBe(true)
  })
})

describe('registration rules (#190)', () => {
  const base = { ...valid, noPhone: false, noPhoneReason: '', phone: '98450 00001' }
  const errorsOf = (v: Record<string, unknown>) => {
    const r = patientSchema.safeParse(v)
    return r.success ? [] : r.error.issues.map((i) => i.path.join('.'))
  }

  it('accepts a single-name patient (blank last name)', () => {
    expect(errorsOf({ ...base, lastName: '' })).toEqual([])
    expect(toCreatePatientRequest(patientSchema.parse({ ...base, lastName: '  ' })).lastName).toBe('')
  })

  it('requires the sex to be chosen; Unknown is an explicit choice', () => {
    expect(errorsOf({ ...base, sex: '' })).toEqual(['sex'])
    expect(errorsOf({ ...base, sex: 'unknown' })).toEqual([])
  })

  it('requires a date of birth or an age, and sends ageYears only without a DOB', () => {
    expect(errorsOf({ ...base, dateOfBirth: '' })).toEqual(['dateOfBirth'])
    expect(errorsOf({ ...base, dateOfBirth: '', ageYears: '121' })).toEqual(['ageYears'])
    expect(errorsOf({ ...base, dateOfBirth: '', ageYears: '4.5' })).toEqual(['ageYears'])
    const byAge = toCreatePatientRequest(patientSchema.parse({ ...base, dateOfBirth: '', ageYears: ' 45 ' }))
    expect(byAge).toMatchObject({ dateOfBirth: null, ageYears: 45 })
    expect(toCreatePatientRequest(patientSchema.parse({ ...base, ageYears: '45' }))).not.toHaveProperty('ageYears')
  })

  it('requires a mobile number or a no-phone reason', () => {
    expect(errorsOf({ ...base, phone: '' })).toEqual(['phone'])
    expect(errorsOf({ ...base, phone: '', noPhone: true, noPhoneReason: 'no' })).toEqual(['noPhoneReason'])
    const none = toCreatePatientRequest(patientSchema.parse({ ...base, phone: '', noPhone: true, noPhoneReason: ' Elderly, no phone ' }))
    expect(none).toMatchObject({ phone: null, noPhoneReason: 'Elderly, no phone' })
    expect(toCreatePatientRequest(patientSchema.parse(base))).not.toHaveProperty('noPhoneReason')
  })
})
