import { useId, type ReactNode } from 'react'
import { Illustration } from '../../components/ui/Illustration'
import { formatDayLabel, formatTime } from '../../lib/dates'
import type { Slot } from '../../lib/api/types'
import { Button } from '../../components/ui/Button'

/**
 * Free-slot radio group (times in the branch zone), shared by booking and rescheduling. A
 * composition of native radios in Tailux-styled labels; `slots` is the useSlots query.
 */
export function SlotPicker({
  timeZone,
  practitionerId,
  slots,
  value,
  onChange,
  emptyHint,
  emptyReason,
  nextDate,
  onNextDate,
}: {
  timeZone: string
  practitionerId: string
  slots: { data?: Slot[]; isPending: boolean; isError: boolean; isPlaceholderData: boolean; isFetching: boolean }
  value: Slot | null
  onChange: (slot: Slot) => void
  /** Shown under the reason (e.g. a link to working hours for admins). */
  emptyHint?: ReactNode
  /** Why this day has no free slots. */
  emptyReason?: string
  /** Next date with a free slot, or null when the look-ahead finished empty. */
  nextDate?: string | null
  onNextDate?: (date: string) => void
}) {
  const group = useId()
  return (
    <fieldset aria-describedby={`${group}-tz`} data-testid="slot-list">
      <legend className="text-sm font-medium text-gray-800 dark:text-dark-100">Free slots</legend>
      <p id={`${group}-tz`} className="text-xs text-gray-600 dark:text-dark-200">
        Times in {timeZone}
      </p>
      {!practitionerId && <p className="text-sm text-gray-600 dark:text-dark-200">Choose a practitioner first.</p>}
      {practitionerId && slots.isPending && <p className="text-sm text-gray-600 dark:text-dark-200">Loading slots…</p>}
      {slots.isError && <p className="text-sm text-error-darker dark:text-error-lighter">Slots are unavailable right now.</p>}
      {slots.data?.length === 0 && !slots.isPlaceholderData && (
        <div className="space-y-2 text-sm text-gray-600 dark:text-dark-200" data-testid="no-free-slots">
          <Illustration name="clock" size={72} className="mx-auto mb-2 block" />
          <p data-testid="slot-empty-reason">{emptyReason ?? 'No free slots on this day.'}</p>
          {nextDate && onNextDate && (
            <Button variant="secondary" onClick={() => onNextDate(nextDate)} data-testid="next-free-day">
              Next free day ({formatDayLabel(nextDate)})
            </Button>
          )}
          {nextDate === null && <p>No free slot in the next 31 days.</p>}
          {emptyHint ? <p>{emptyHint}</p> : null}
        </div>
      )}
      <div className={`mt-2 flex flex-wrap gap-2 ${slots.isPlaceholderData ? 'opacity-50' : ''}`} aria-busy={slots.isFetching}>
        {slots.data?.map((s) => {
          const checked = value?.startsAt === s.startsAt
          return (
            <label
              key={s.startsAt}
              className={`cursor-pointer rounded border px-2 py-1 text-sm font-mono ${checked ? 'border-primary-600 dark:border-primary-400 bg-primary-50 dark:bg-primary-500/15' : 'border-gray-300 dark:border-dark-450'}`}
            >
              <input type="radio" name={group} className="sr-only" checked={checked} disabled={slots.isPlaceholderData} onChange={() => onChange(s)} />
              {formatTime(s.startsAt, timeZone)}
            </label>
          )
        })}
      </div>
    </fieldset>
  )
}
