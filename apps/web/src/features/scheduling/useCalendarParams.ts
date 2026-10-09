import { useSearchParams } from 'react-router'
import { addDays, isCalendarDate, localToday, startOfWeek } from '../../lib/dates'

export type CalendarView = 'day' | 'week'

/**
 * `?date=` and `?view=` of a calendar screen. "Today" is the branch-local date (the branch's IANA
 * zone), never the UTC date. Navigation steps by a day or a week depending on the view.
 */
export function useCalendarParams(timeZone: string, defaultView: CalendarView = 'day') {
  const [params, setParams] = useSearchParams()
  const today = localToday(new Date(), timeZone)
  const rawDate = params.get('date') ?? ''
  const date = isCalendarDate(rawDate) ? rawDate : today
  const view: CalendarView = params.get('view') === 'week' ? 'week' : params.get('view') === 'day' ? 'day' : defaultView
  const rangeStart = view === 'week' ? startOfWeek(date) : date
  const rangeEnd = addDays(rangeStart, view === 'week' ? 7 : 1) // exclusive

  const update = (patch: Record<string, string>) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        for (const [k, v] of Object.entries(patch)) next.set(k, v)
        return next
      },
      { replace: true },
    )

  return {
    today,
    date,
    view,
    rangeStart,
    rangeEnd,
    setDate: (d: string) => update({ date: d }),
    setView: (v: CalendarView) => update({ view: v }),
    step: (direction: 1 | -1) => update({ date: addDays(date, direction * (view === 'week' ? 7 : 1)) }),
    goToday: () => update({ date: today }),
  }
}
