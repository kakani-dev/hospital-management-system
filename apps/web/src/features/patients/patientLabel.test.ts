import { describe, expect, it } from 'vitest'
import { exactMrnFirst, isExactMrn } from './patientLabel'

const a = { mrn: 'ALP-0001' }
const b = { mrn: 'ALP-00010' }
const c = { mrn: 'ALP-0010' }

describe('exact-MRN first', () => {
  it('moves the exact match (case-insensitive, trimmed) to the top and keeps the rest in order', () => {
    expect(exactMrnFirst([b, c, a], ' alp-0001 ')).toEqual({ items: [a, b, c], exact: a })
    expect(exactMrnFirst([a, b, c], 'ALP-0001').items).toEqual([a, b, c])
  })

  it('leaves partial matches and short terms alone', () => {
    const items = [b, c, a]
    expect(exactMrnFirst(items, 'ALP-00')).toEqual({ items, exact: null })
    expect(isExactMrn({ mrn: 'A' }, 'a')).toBe(false) // below the 2-character minimum
    expect(isExactMrn({ mrn: 'AB' }, 'ab')).toBe(true)
  })
})
