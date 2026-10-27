import { describe, expect, it } from 'vitest'
import { collectAmount, planTenders, splitQuantity } from './collect'

describe('collect helpers (#172, #173)', () => {
  it('reads a trailing number as the quantity', () => {
    expect(splitQuantity('ecg 2')).toEqual({ text: 'ecg', quantity: 2 })
    expect(splitQuantity('ECG x3')).toEqual({ text: 'ECG', quantity: 3 })
    expect(splitQuantity('dressing')).toEqual({ text: 'dressing', quantity: null })
    expect(splitQuantity('42')).toEqual({ text: '42', quantity: null })
    expect(splitQuantity('ecg 0')).toEqual({ text: 'ecg 0', quantity: null })
  })

  it('empty amount collects the full due in the chosen mode', () => {
    expect(planTenders('upi', 50000, '', '', 'UTR1')).toEqual({ tenders: [{ mode: 'upi', amountPaise: 50000, reference: 'UTR1' }], totalPaise: 50000 })
  })

  it('cash above the due records only the due (rest is change)', () => {
    expect(planTenders('cash', 50000, '1000', '', '')).toEqual({ tenders: [{ mode: 'cash', amountPaise: 50000 }], totalPaise: 50000 })
  })

  it('a smaller amount is a partial payment', () => {
    expect(collectAmount('cash', 50000, '200', '')).toBe(20000)
  })

  it('card or UPI above the due is refused', () => {
    expect(planTenders('card', 50000, '600', '', '')).toHaveProperty('error')
  })

  it('split takes cash plus UPI and fills UPI with the rest', () => {
    expect(planTenders('split', 50000, '300', '', '')).toEqual({
      tenders: [{ mode: 'cash', amountPaise: 30000 }, { mode: 'upi', amountPaise: 20000 }],
      totalPaise: 50000,
    })
    expect(planTenders('split', 50000, '300', '300', '')).toHaveProperty('error')
    expect(planTenders('split', 50000, '500', '', '')).toHaveProperty('error')
  })

  it('rejects junk and zero', () => {
    expect(planTenders('cash', 50000, 'abc', '', '')).toHaveProperty('error')
    expect(planTenders('cash', 50000, '0', '', '')).toHaveProperty('error')
  })
})
