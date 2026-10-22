import { describe, expect, it } from 'vitest'
import { emptyDayText, explainEmptyDay, nextFreeDate, practitionersAtBranch, schedulesOn } from './scheduleUtils'
import type { Practitioner, Schedule } from '../../lib/api/types'

const base: Schedule = {
  id: 's1',
  practitionerId: 'd1',
  branchId: 'b1',
  weekday: 5,
  startTime: '09:00',
  endTime: '13:00',
  slotMinutes: 15,
  validFrom: '2026-10-01',
  validTo: null,
  isActive: true,
}

describe('schedulesOn', () => {
  it('matches ISO weekday, validity window and active flag', () => {
    const schedules: Schedule[] = [
      base,
      { ...base, id: 's2', startTime: '14:00', endTime: '17:00' },
      { ...base, id: 's3', isActive: false },
      { ...base, id: 's4', validTo: '2026-10-08' },
      { ...base, id: 's5', weekday: 1 },
      { ...base, id: 's6', practitionerId: 'd2', validFrom: '2026-10-10' },
    ]
    expect(schedulesOn(schedules, '2026-10-09').map((s) => s.id)).toEqual(['s1', 's2']) // Friday
    expect(schedulesOn(schedules, '2026-10-05').map((s) => s.id)).toEqual(['s5']) // Monday
    expect(schedulesOn(schedules, '2026-10-16', 'd2').map((s) => s.id)).toEqual(['s6'])
  })
})

describe('explainEmptyDay', () => {
  const noon = new Date('2026-10-09T06:30:00Z') // 12:00 in Asia/Kolkata
  it('names no schedule, a finished day, and a day that still has hours', () => {
    expect(explainEmptyDay([], '2026-10-09', 'd1', noon, 'Asia/Kolkata')).toBe('no_schedule')
    expect(explainEmptyDay([base], '2026-10-02', 'd1', noon, 'Asia/Kolkata')).toBe('day_over')
    expect(explainEmptyDay([base], '2026-10-09', 'd1', noon, 'Asia/Kolkata')).toBe('fully_booked')
    expect(explainEmptyDay([base], '2026-10-09', 'd1', new Date('2026-10-09T08:00:00Z'), 'Asia/Kolkata')).toBe('day_over')
    expect(emptyDayText('no_schedule')).toMatch(/no working hours/)
  })
  it('picks the earliest date that still has a slot', () => {
    const slot = (startsAt: string) => ({ practitionerId: 'd1', branchId: 'b1', startsAt, endsAt: startsAt })
    expect(nextFreeDate([slot('2026-10-12T04:30:00Z'), slot('2026-10-11T04:30:00Z')], 'Asia/Kolkata')).toBe('2026-10-11')
    expect(nextFreeDate([], 'Asia/Kolkata')).toBeNull()
  })
})

describe('practitionersAtBranch', () => {
  const p = (id: string, isActive = true): Practitioner => ({ id, userId: null, displayName: id, specialty: null, isActive })
  it('offers scheduled practitioners, or every active one when the branch has no schedules', () => {
    expect(practitionersAtBranch([p('d1'), p('d2'), p('d3', false)], [base]).map((x) => x.id)).toEqual(['d1'])
    expect(practitionersAtBranch([p('d1'), p('d2'), p('d3', false)], []).map((x) => x.id)).toEqual(['d1', 'd2'])
  })
})
