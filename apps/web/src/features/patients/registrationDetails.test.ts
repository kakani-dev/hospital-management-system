import { describe, expect, it } from 'vitest'
import { addDays, localToday } from '../../lib/dates'
import { ageFrom, EMPTY_DETAILS, fromDetails, registerPatientSchema, toDetailsInput } from './patientSchema'

// #58: relative dates only.
const today = localToday()
const yearsAgo = (n: number, extraDays = 0) => addDays(`${Number(today.slice(0, 4)) - n}${today.slice(4)}`, extraDays)

describe('registration details (#58)', () => {
  it('age counts the birthday, falls back to the typed age, else unknown', () => {
    expect(ageFrom(yearsAgo(18), '', today)).toBe(18)
    expect(ageFrom(yearsAgo(18, 1), '', today)).toBe(17)
    expect(ageFrom('', '7', today)).toBe(7)
    expect(ageFrom('', '', today)).toBeNull()
  })

  it('an untouched section (walk-in default) sends nothing; blanks become null', () => {
    expect(toDetailsInput({ ...EMPTY_DETAILS })).toBeNull()
    const out = toDetailsInput({ ...EMPTY_DETAILS, guardianName: ' Zz-QA Parent ' })
    expect(out?.guardianName).toBe('Zz-QA Parent')
    expect(out?.pinCode).toBeNull()
    expect(out?.referralSource).toBe('walk_in')
  })

  it('edit form round-trips stored details and defaults the referral to walk-in', () => {
    expect(fromDetails(null).referralSource).toBe('walk_in')
    expect(fromDetails({ bloodGroup: 'O+', referralSource: 'doctor' })).toMatchObject({ bloodGroup: 'O+', referralSource: 'doctor', city: '' })
  })

  it('rejects a PIN starting with 0 or not 6 digits, accepts one typed with a space', () => {
    const base = { firstName: 'Zz-QA', lastName: 'Pin', dateOfBirth: '', ageYears: '40', sex: 'female', registeredBranchId: '00000000-0000-4000-8000-000000000001',
      phone: '', noPhone: true, noPhoneReason: 'no phone', email: '', whatsappSameAsPhone: true, whatsappNumber: '', abhaNumber: '' }
    const pin = (pinCode: string) => registerPatientSchema.safeParse({ ...base, details: { ...EMPTY_DETAILS, pinCode } }).success
    expect(pin('560 001')).toBe(true)
    expect(pin('060001')).toBe(false)
    expect(pin('56001')).toBe(false)
  })
})
