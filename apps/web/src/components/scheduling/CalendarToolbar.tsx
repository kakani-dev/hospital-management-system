import { useId } from 'react'
import clsx from 'clsx'
import { Button as TxButton, Input } from '@tailux/components/ui'
import { ChevronLeftIcon, ChevronRightIcon } from '@heroicons/react/20/solid'
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
      <Button variant="secondary" onClick={() => onStep(-1)} aria-label={`Previous ${unit}`} className="px-2.5">
        <ChevronLeftIcon className="size-5" aria-hidden="true" />
      </Button>
      <Button variant="secondary" onClick={onToday}>
        Today
      </Button>
      <Button variant="secondary" onClick={() => onStep(1)} aria-label={`Next ${unit}`} className="px-2.5">
        <ChevronRightIcon className="size-5" aria-hidden="true" />
      </Button>
      <Input
        id={dateId}
        label="Date"
        classNames={{ root: 'w-auto', label: 'font-medium text-gray-800 dark:text-dark-100' }}
        type="date"
        value={date}
        onChange={(e) => e.target.value && onDate(e.target.value)}
      />
      {onView && (
        // Tailux button group (demo components/button: grouped outlined buttons).
        <div role="group" aria-label="Calendar view" className="flex">
          {(['day', 'week'] as const).map((v, i) => (
            <TxButton
              key={v}
              type="button"
              aria-pressed={view === v}
              onClick={() => onView(v)}
              color={view === v ? 'primary' : 'neutral'}
              variant={view === v ? 'filled' : 'outlined'}
              className={clsx(
                'h-9 px-4 text-sm',
                i === 0 ? 'ltr:rounded-r-none rtl:rounded-l-none' : 'ltr:-ml-px ltr:rounded-l-none rtl:-mr-px rtl:rounded-r-none',
              )}
            >
              {v === 'day' ? 'Day' : 'Week'}
            </TxButton>
          ))}
        </div>
      )}
      <p className="ml-auto text-sm font-medium text-gray-700 dark:text-dark-200" aria-live="polite" data-testid="calendar-range">
        {label}
      </p>
    </div>
  )
}
