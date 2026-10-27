import { useState } from 'react'
import { Alert } from '../../components/ui/Alert'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { FormField } from '../../components/ui/FormField'
import { useRescheduleAppointment, useSlots } from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { transientWriteMessage } from '../../lib/api/errors'
import { dateInZone, formatDayLabel, formatTime } from '../../lib/dates'
import type { Appointment, Practitioner, Slot } from '../../lib/api/types'
import { SlotPicker } from './SlotPicker'

/**
 * Move a booked appointment to another free slot (same branch; optionally another practitioner)
 * via POST /appointments/{id}/reschedule. A 409 means the slot went meanwhile: slots refresh.
 */
export function ReschedulePanel({
  appointment,
  patientName,
  timeZone,
  minDate,
  practitioners,
  onCancel,
  onRescheduled,
}: {
  appointment: Appointment
  patientName: string
  timeZone: string
  minDate: string
  practitioners: Practitioner[]
  onCancel: () => void
  onRescheduled: (appointment: Appointment, message: string) => void
}) {
  const current = dateInZone(appointment.startsAt, timeZone)
  const [practitionerId, setPractitionerId] = useState(appointment.practitionerId)
  const [date, setDate] = useState(current < minDate ? minDate : current)
  const [slot, setSlot] = useState<Slot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [retryable, setRetryable] = useState(false)
  // Keep the visit's length: only offer starts where the whole visit fits the hours and no other booking.
  const visitMinutes = Math.round((Date.parse(appointment.endsAt) - Date.parse(appointment.startsAt)) / 60_000)
  const slots = useSlots(appointment.branchId, practitionerId, date, visitMinutes >= 5 && visitMinutes <= 480 ? visitMinutes : undefined)
  const reschedule = useRescheduleAppointment()
  // The current practitioner stays selectable even if no longer bookable here.
  const options = practitioners.some((p) => p.id === appointment.practitionerId)
    ? practitioners
    : [{ id: appointment.practitionerId, displayName: 'Current practitioner', specialty: null, userId: null, isActive: true }, ...practitioners]

  const submit = async () => {
    setError(null)
    setRetryable(false)
    if (!slot) {
      setError('Choose a free slot.')
      return
    }
    try {
      const moved = await reschedule.mutateAsync({
        id: appointment.id,
        body: {
          startsAt: slot.startsAt,
          endsAt: slot.endsAt,
          ...(practitionerId !== appointment.practitionerId ? { practitionerId } : {}),
        },
      })
      onRescheduled(moved, `Moved ${patientName} to ${formatDayLabel(date)} at ${formatTime(slot.startsAt, timeZone)}.`)
    } catch (e) {
      const transient = transientWriteMessage(e, 'reschedule the appointment')
      if (transient) {
        setError(transient)
        setRetryable(true)
        return
      }
      setSlot(null)
      const code = problemCode(e)
      const status = e instanceof ApiError ? e.status : 0
      setError(
        code === 'appointment_overlap'
          ? 'That slot was just taken. Pick another slot.'
          : code === 'invalid_transition'
            ? 'Only booked appointments can be rescheduled (it may have been checked in or cancelled).'
            : status === 403
              ? 'You are not allowed to reschedule appointments at this branch.'
              : status === 404
                ? 'This appointment no longer exists.'
                : (Object.values(fieldErrors(e))[0] ?? 'Could not reschedule the appointment. Try again.'),
      )
    }
  }

  return (
    <form
      aria-label="Reschedule appointment"
      noValidate
      className="space-y-4"
      onSubmit={(e) => {
        e.preventDefault()
        void submit()
      }}
    >
      <p className="text-sm text-gray-700 dark:text-dark-100" data-testid="reschedule-current">
        {patientName}: now {formatDayLabel(current)} at {formatTime(appointment.startsAt, timeZone)}
      </p>
      <SelectField
        label="Practitioner"
        value={practitionerId}
        onChange={(e) => {
          setPractitionerId(e.target.value)
          setSlot(null)
        }}
      >
        {options.map((p) => (
          <option key={p.id} value={p.id}>
            {p.displayName}
            {p.specialty ? ` (${p.specialty})` : ''}
          </option>
        ))}
      </SelectField>
      <FormField
        label="New date"
        type="date"
        min={minDate}
        value={date}
        onChange={(e) => {
          if (e.target.value) setDate(e.target.value)
          setSlot(null)
        }}
      />
      <SlotPicker timeZone={timeZone} practitionerId={practitionerId} slots={slots} value={slot} onChange={setSlot} />
      {error && (retryable ? <RetryAlert message={error} onRetry={() => void submit()} busy={reschedule.isPending} /> : <Alert tone="error">{error}</Alert>)}
      <div className="flex gap-2">
        <Button type="submit" disabled={reschedule.isPending}>
          {reschedule.isPending ? 'Moving…' : 'Confirm new time'}
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Close
        </Button>
      </div>
    </form>
  )
}
