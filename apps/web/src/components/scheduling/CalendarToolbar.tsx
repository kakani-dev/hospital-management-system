import { useId } from 'react'
import { Button } from '../ui/Button'
import type { CalendarView } from '../../features/scheduling/useCalendarParams'

/** Prev / Today / Next, a date input and (optionally) the Day | Week switch. */
export function CalendarToolbar({
  date,
  view,
  onStep,
  onToday,
  onDate,
  onView,
  label,
}: {
  date: string
  view: CalendarView
  onStep: (direction: 1 | -1) => void
  onToday: () => void
  onDate: (date: string) => void
  onView?: (view: CalendarView) => void
  label: string
}) {
  const dateId = useId()
  const unit = view === 'week' ? 'week' : 'day'
  return (
    <div className="flex flex-wrap items-end gap-2" role="toolbar" aria-label="Calendar navigation">
      <Button variant="secondary" onClick={() => onStep(-1)} aria-label={`Previous ${unit}`}>
        ‹
      </Button>
      <Button variant="secondary" onClick={onToday}>
        Today
      </Button>
      <Button variant="secondary" onClick={() => onStep(1)} aria-label={`Next ${unit}`}>
        ›
      </Button>
      <div>
        <label htmlFor={dateId} className="block text-sm font-medium text-slate-800">
          Date
        </label>
        <input
          id={dateId}
          type="date"
          value={date}
          onChange={(e) => e.target.value && onDate(e.target.value)}
          className="mt-1 block rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
      </div>
      {onView && (
        <div role="group" aria-label="Calendar view" className="flex overflow-hidden rounded-md border border-slate-300">
          {(['day', 'week'] as const).map((v) => (
            <button
              key={v}
              type="button"
              aria-pressed={view === v}
              onClick={() => onView(v)}
              className={`px-3 py-2 text-sm font-medium ${view === v ? 'bg-brand-700 text-white' : 'bg-white text-slate-800 hover:bg-slate-100'}`}
            >
              {v === 'day' ? 'Day' : 'Week'}
            </button>
          ))}
        </div>
      )}
      <p className="ml-auto text-sm font-medium text-slate-700" aria-live="polite" data-testid="calendar-range">
        {label}
      </p>
    </div>
  )
}
