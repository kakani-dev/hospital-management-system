import { describe, expect, it } from 'vitest'
import { patientSchema, toCreatePatientRequest } from './patientSchema'

const valid = {
  mrn: 'ALP-0100',
  firstName: 'Asha',
  lastName: 'Synthetic',
  dateOfBirth: '1990-01-01',
  sex: 'female' as const,
  registeredBranchId: 'a1111111-0000-4000-8000-000000000001',
  phone: '',
  email: '',
}

describe('patientSchema', () => {
  it('accepts a valid patient and normalises optional fields to null', () => {
    const parsed = patientSchema.parse(valid)
    expect(toCreatePatientRequest(parsed)).toMatchObject({ phone: null, email: null, dateOfBirth: '1990-01-01' })
  })

  it.each([
    ['mrn', 'has space'],
    ['mrn', 'x'.repeat(33)],
    ['firstName', '  '],
    ['dateOfBirth', '1899-12-31'],
    ['dateOfBirth', '2999-01-01'],
    ['registeredBranchId', ''],
    ['email', 'not-an-email'],
  ])('rejects invalid %s (%s)', (field, value) => {
    expect(patientSchema.safeParse({ ...valid, [field]: value }).success).toBe(false)
  })
})
