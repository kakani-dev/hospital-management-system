import { describe, expect, it } from 'vitest'
import { patientSchema, toCreatePatientRequest } from './patientSchema'

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
