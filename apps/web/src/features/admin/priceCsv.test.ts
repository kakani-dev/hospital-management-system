import { describe, expect, it } from 'vitest'
import { PRICE_CSV_TEMPLATE, parsePriceCsv, splitCsvLine } from './priceCsv'

describe('parsePriceCsv', () => {
  it('reads the template, including a quoted comma, as paise', () => {
    const parsed = parsePriceCsv(PRICE_CSV_TEMPLATE)
    expect(parsed.fileError).toBeNull()
    expect(parsed.rows.map((row) => [row.code, row.sac, row.unitPricePaise, row.branchCode, row.name])).toEqual([
      ['', '', 15000, '', 'Wound dressing'],
      ['', '', 20000, 'main', 'Medical certificate, fitness'],
    ])
    expect(parsed.rows.every((row) => row.error === null)).toBe(true)
  })

  it('rejects a bad amount and a header without the required columns', () => {
    expect(parsePriceCsv('code,name\nDRESS,Dressing\n').fileError).toMatch(/header/i)
    const parsed = parsePriceCsv('code,rupees,effective_from\nDRESS,10.555,2026-04-01\n,150,2026-04-01\n')
    expect(parsed.rows[0]?.error).toMatch(/rupees/i)
    expect(parsed.rows[1]?.error).toMatch(/name/i)
    const named = parsePriceCsv('name,rupees,effective_from\nSuture,150,2026-04-01\n')
    expect(named.fileError).toBeNull()
    expect(named.rows[0]?.error).toBeNull()
    expect(named.rows[0]?.code).toBe('')
    expect(named.rows[0]?.sac).toBe('')
  })

  it('splits quotes without breaking on commas', () => {
    expect(splitCsvLine('CERT,"Medical certificate, fitness",200')).toEqual(['CERT', 'Medical certificate, fitness', '200'])
  })
})
