import { afterEach, describe, expect, it } from 'vitest'
import { ApiError } from '../../lib/api/client'
import { errorText, changeDue, classifySearch, collectionByMode, quickTenders, rememberedBranch, waitingCount, waitingToPay } from './counter'
import type { BillListItem, QueueEntry } from '../../lib/api/types'

const now = Date.now()
const iso = (minsAgo: number) => new Date(now - minsAgo * 60_000).toISOString()

describe('classifySearch', () => {
  it.each([
    ['12-3456-7890-1234', { abha: '12-3456-7890-1234' }],
    ['12345678901234', { abha: '12345678901234' }],
    ['98450 12345', { phone: '98450 12345' }],
    ['+91 9845012345', { phone: '+91 9845012345' }],
    ['DEMOB2627', { search: 'DEMOB2627' }],
    ['Zz', { search: 'Zz' }],
    ['a', null],
    ['  ', null],
  ])('%s', (term, want) => expect(classifySearch(term)).toEqual(want))
})

describe('quickTenders and change', () => {
  it('starts with the exact due and rounds up to likely notes', () => {
    expect(quickTenders(35000)).toEqual([350, 400, 500, 2000])
    expect(quickTenders(70000)).toEqual([700, 800, 1000, 2000])
  })
  it('is empty when nothing is due', () => expect(quickTenders(0)).toEqual([]))
  it('gives change only when more is received', () => {
    expect(changeDue(35000, 50000)).toBe(15000)
    expect(changeDue(35000, 35000)).toBe(0)
    expect(changeDue(35000, null)).toBe(0)
  })
})

describe('side panel helpers', () => {
  const bill = (id: string, due: number, mins: number, status = 'draft') =>
    ({ id, patientId: `p-${id}`, status, duePaise: due, createdOn: iso(mins) }) as unknown as BillListItem
  const q = (patientId: string, practitionerId: string, status: string, tokenNo: number) =>
    ({ patientId, practitionerId, status, tokenNo }) as unknown as QueueEntry

  it('lists unpaid drafts newest first with their token', () => {
    const rows = waitingToPay([bill('b', 100, 5), bill('a', 100, 30), bill('c', 0, 40), bill('d', 100, 50, 'final')], [q('p-a', 'd1', 'waiting', 7)])
    expect(rows.map((r) => r.bill.id)).toEqual(['b', 'a']) // newest first: a just-issued token is on top
    expect(rows[1]?.token).toBe(7)
    expect(rows[0]?.token).toBeNull()
  })
  it('sums collection by mode, biggest first', () => {
    const rows = collectionByMode([
      { mode: 'cash', netPaise: 1000, count: 1 },
      { mode: 'upi', netPaise: 5000, count: 2 },
      { mode: 'cash', netPaise: 500, count: 1 },
    ] as never)
    expect(rows).toEqual([{ mode: 'upi', netPaise: 5000, count: 2 }, { mode: 'cash', netPaise: 1500, count: 2 }])
  })
  it('counts only waiting tokens for the doctor', () => {
    expect(waitingCount([q('x', 'd1', 'waiting', 1), q('y', 'd1', 'done', 2), q('z', 'd2', 'waiting', 3)], 'd1')).toBe(1)
  })
})

describe('rememberedBranch', () => {
  afterEach(() => localStorage.clear())
  it('is per user', () => {
    rememberedBranch.set('u1', 'b1')
    expect(rememberedBranch.get('u1')).toBe('b1')
    expect(rememberedBranch.get('u2')).toBeNull()
    expect(rememberedBranch.get(undefined)).toBeNull()
  })
})

describe('errorText', () => {
  it('prefers the server detail over the HTTP title', () => {
    expect(errorText(new ApiError(409, { title: 'Conflict', detail: 'Already checked in today.' }))).toBe('Already checked in today.')
    expect(errorText(new ApiError(409, { title: 'Conflict' }))).toBe('Conflict')
    expect(errorText('x')).toBe('Something went wrong.')
  })
})
