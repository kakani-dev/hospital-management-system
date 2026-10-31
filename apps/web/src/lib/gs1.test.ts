import { describe, expect, it } from 'vitest'
import { gs1Date, gtinValid, parseGs1 } from './gs1'

const GS = '\u001d'
const now = new Date()
const yy = (add: number) => String((now.getFullYear() + add) % 100).padStart(2, '0')
// Synthetic GTIN-14 with a valid check digit (no real product).
const GTIN = '08901234567890'

describe('GS1 parsing', () => {
  it('validates GTIN check digits', () => {
    expect(gtinValid(GTIN)).toBe(true)
    expect(gtinValid('08901234567891')).toBe(false)
    expect(gtinValid('4006381333931')).toBe(true) // EAN-13
  })

  it('reads a DataMatrix with FNC1 separators and an AIM prefix', () => {
    const r = parseGs1(`]d201${GTIN}17${yy(2)}063010ZZQA-B12${GS}21SER0001`, now)
    expect(r).toEqual({ gtin: GTIN, expiry: `${now.getFullYear() + 2}-06-30`, batch: 'ZZQA-B12', serial: 'SER0001' })
  })

  it('reads the bracketed human-readable form in any AI order', () => {
    expect(parseGs1(`(01)${GTIN}(10)B7 (17)${yy(1)}1200`, now)).toEqual({ gtin: GTIN, batch: 'B7', expiry: `${now.getFullYear() + 1}-12-31` })
  })

  it('lets a trailing variable field run to the end when the scanner drops GS', () => {
    expect(parseGs1(`01${GTIN}17${yy(1)}010110LOT9`, now).batch).toBe('LOT9')
  })

  it('takes a plain EAN-13 as a GTIN', () => {
    expect(parseGs1('4006381333931\r\n')).toEqual({ gtin: '04006381333931' })
  })

  it.each([
    ['', 'Nothing was scanned.'],
    ['01089012345678911712', 'check digit'],
    [`01${GTIN}17${yy(1)}1301`, 'expiry date'],
    ['hello', 'not a GS1'],
    ['10ONLYLOT', 'No product code'],
  ])('rejects %j', (raw, msg) => {
    expect(parseGs1(raw, now).error).toContain(msg)
  })

  it('uses the GS1 century window', () => {
    const ref = new Date(Date.UTC(2026, 9, 31))
    expect(gs1Date('761231', ref)).toBe('2076-12-31')
    expect(gs1Date('770101', ref)).toBe('1977-01-01')
    expect(gs1Date('280200', ref)).toBe('2028-02-29')
  })
})
