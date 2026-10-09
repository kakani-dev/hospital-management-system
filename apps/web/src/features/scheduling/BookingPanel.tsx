import { useEffect, useId, useRef, useState } from 'react'
import { useLocation } from 'react-router'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { transientWriteMessage } from '../../lib/api/errors'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { FormField } from '../../components/ui/FormField'
import { useCreateAppointment, useSlots } from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { formatDayLabel, formatTime } from '../../lib/dates'
import type { Appointment, PatientSummary, Practitioner, Slot } from '../../lib/api/types'
import { PatientPicker } from '../patients/PatientPicker'

/** Booking panel fields that survive a round trip through "Register new patient" (router state). */
export interface BookingDraft {
  practitionerId?: string
  date?: string
  slot?: Slot | null
}

/** Book: pick practitioner → date → free slot → patient. Conflicts (409) refresh the slots. */
export function BookingPanel({
  branchId,
  timeZone,
  initialDate,
  minDate,
  practitioners,
  onCancel,
  onBooked,
  initial,
}: {
  branchId: string
  timeZone: string
  initialDate: string
  minDate: string
  practitioners: Practitioner[]
  onCancel: () => void
  onBooked: (appointment: Appointment, message: string) => void
  /** Restored panel state, e.g. after "Register new patient" came back with the new patient. */
  initial?: BookingDraft & { patient?: PatientSummary | null }
}) {
  const location = useLocation()
  const [practitionerId, setPractitionerId] = useState(initial?.practitionerId ?? '')
  const [date, setDate] = useState(initial?.date ?? initialDate)
  const [slot, setSlot] = useState<Slot | null>(initial?.slot ?? null)
  const [patient, setPatient] = useState<PatientSummary | null>(initial?.patient ?? null)
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [retryable, setRetryable] = useState(false)
  const confirmRef = useRef<HTMLButtonElement>(null)
  // Back from registration with everything filled in: Enter confirms.
  useEffect(() => {
    if (initial?.patient) confirmRef.current?.focus()
  }, [initial?.patient])
  const slots = useSlots(branchId, practitionerId, date)
  const create = useCreateAppointment()
  const slotGroup = useId()

  const submit = async () => {
    setError(null)
    setRetryable(false)
    if (!practitionerId || !slot || !patient) {
      setError('Choose a practitioner, a free slot and a patient.')
      return
    }
    try {
      const appointment = await create.mutateAsync({
        branchId,
        practitionerId,
        patientId: patient.id,
        startsAt: slot.startsAt,
        endsAt: slot.endsAt,
        ...(reason.trim() ? { reason: reason.trim() } : {}),
      })
      const doctor = practitioners.find((p) => p.id === practitionerId)?.displayName ?? 'the practitioner'
      onBooked(
        appointment,
        `Booked ${patient.firstName} ${patient.lastName} with ${doctor} on ${formatDayLabel(date)} at ${formatTime(slot.startsAt, timeZone)}.`,
      )
    } catch (e) {
      // Cold server / timeout: keep the form as it is and offer Retry (writes are never auto-retried).
      const transient = transientWriteMessage(e, 'book the appointment')
      if (transient) {
        setError(transient)
        setRetryable(true)
        return
      }
      setSlot(null)
      const code = problemCode(e)
      const status = e instanceof ApiError ? e.status : 0
      setError(
        status === 409 || code === 'appointment_overlap'
          ? 'That slot was just booked for this practitioner. Pick another slot.'
          : code === 'invalid_reference' || status === 404
            ? 'The patient or practitioner can no longer be booked (deleted or inactive).'
            : status === 403
              ? 'You are not allowed to book appointments at this branch.'
              : (Object.values(fieldErrors(e))[0] ?? 'Could not book the appointment. Try again.'),
      )
    }
  }

  return (
    <form
      aria-label="Book appointment"
      noValidate
      className="grid gap-4 md:grid-cols-2"
      onSubmit={(e) => {
        e.preventDefault()
        void submit()
      }}
    >
      <div className="space-y-4">
        <SelectField
          label="Practitioner"
          value={practitionerId}
          onChange={(e) => {
            setPractitionerId(e.target.value)
            setSlot(null)
          }}
        >
          <option value="">Select a practitioner…</option>
          {practitioners.map((p) => (
            <option key={p.id} value={p.id}>
              {p.displayName}
              {p.specialty ? ` (${p.specialty})` : ''}
            </option>
          ))}
        </SelectField>
        <FormField
          label="Appointment date"
          type="date"
          min={minDate}
          value={date}
          onChange={(e) => {
            if (e.target.value) setDate(e.target.value)
            setSlot(null)
          }}
        />
        <fieldset aria-describedby={`${slotGroup}-tz`} data-testid="slot-list">
          <legend className="text-sm font-medium text-gray-800 dark:text-dark-100">Free slots</legend>
          <p id={`${slotGroup}-tz`} className="text-xs text-gray-600 dark:text-dark-200">
            Times in {timeZone}
          </p>
          {!practitionerId && <p className="text-sm text-gray-600 dark:text-dark-200">Choose a practitioner first.</p>}
          {practitionerId && slots.isPending && <p className="text-sm text-gray-600 dark:text-dark-200">Loading slots…</p>}
          {slots.isError && <p className="text-sm text-error dark:text-error-lighter">Slots are unavailable right now.</p>}
          {slots.data?.length === 0 && !slots.isPlaceholderData && <p className="text-sm text-gray-600 dark:text-dark-200">No free slots on this day.</p>}
          <div className={`mt-2 flex flex-wrap gap-2 ${slots.isPlaceholderData ? 'opacity-50' : ''}`} aria-busy={slots.isFetching}>
            {slots.data?.map((s) => {
              const checked = slot?.startsAt === s.startsAt
              return (
                <label
                  key={s.startsAt}
                  className={`cursor-pointer rounded border px-2 py-1 text-sm font-mono ${checked ? 'border-primary-600 dark:border-primary-400 bg-primary-50 dark:bg-primary-500/15' : 'border-gray-300 dark:border-dark-450'}`}
                >
                  <input type="radio" name={slotGroup} className="sr-only" checked={checked} disabled={slots.isPlaceholderData} onChange={() => setSlot(s)} />
                  {formatTime(s.startsAt, timeZone)}
                </label>
              )
            })}
          </div>
        </fieldset>
      </div>
      <div className="space-y-4">
        <PatientPicker
          value={patient}
          onChange={setPatient}
          registerReturn={{ to: `${location.pathname}${location.search}`, state: { booking: { practitionerId, date, slot } satisfies BookingDraft } }}
        />
        <FormField label="Reason (optional)" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </div>
      {error && (
        <div className="md:col-span-2">
          {retryable ? <RetryAlert message={error} onRetry={() => void submit()} busy={create.isPending} /> : <Alert tone="error">{error}</Alert>}
        </div>
      )}
      <div className="flex gap-2 md:col-span-2">
        <Button ref={confirmRef} type="submit" disabled={create.isPending}>
          {create.isPending ? 'Booking…' : 'Confirm booking'}
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Close
        </Button>
      </div>
    </form>
  )
}
