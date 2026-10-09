import { useId, useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { FormField } from '../../components/ui/FormField'
import { useCreateAppointment, useSlots } from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { formatDayLabel, formatTime } from '../../lib/dates'
import type { Appointment, PatientSummary, Practitioner, Slot } from '../../lib/api/types'
import { PatientPicker } from '../patients/PatientPicker'

/** Book: pick practitioner → date → free slot → patient. Conflicts (409) refresh the slots. */
export function BookingPanel({
  branchId,
  timeZone,
  initialDate,
  minDate,
  practitioners,
  onCancel,
  onBooked,
}: {
  branchId: string
  timeZone: string
  initialDate: string
  minDate: string
  practitioners: Practitioner[]
  onCancel: () => void
  onBooked: (appointment: Appointment, message: string) => void
}) {
  const [practitionerId, setPractitionerId] = useState('')
  const [date, setDate] = useState(initialDate)
  const [slot, setSlot] = useState<Slot | null>(null)
  const [patient, setPatient] = useState<PatientSummary | null>(null)
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const slots = useSlots(branchId, practitionerId, date)
  const create = useCreateAppointment()
  const slotGroup = useId()

  const submit = async () => {
    setError(null)
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
    <Card title="Book appointment">
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
            <legend className="text-sm font-medium text-slate-800">Free slots</legend>
            <p id={`${slotGroup}-tz`} className="text-xs text-slate-600">
              Times in {timeZone}
            </p>
            {!practitionerId && <p className="text-sm text-slate-600">Choose a practitioner first.</p>}
            {practitionerId && slots.isPending && <p className="text-sm text-slate-600">Loading slots…</p>}
            {slots.isError && <p className="text-sm text-red-700">Slots are unavailable right now.</p>}
            {slots.data?.length === 0 && <p className="text-sm text-slate-600">No free slots on this day.</p>}
            <div className="mt-2 flex flex-wrap gap-2">
              {slots.data?.map((s) => {
                const checked = slot?.startsAt === s.startsAt
                return (
                  <label
                    key={s.startsAt}
                    className={`cursor-pointer rounded border px-2 py-1 text-sm font-mono ${checked ? 'border-brand-700 bg-brand-50' : 'border-slate-300'}`}
                  >
                    <input type="radio" name={slotGroup} className="sr-only" checked={checked} onChange={() => setSlot(s)} />
                    {formatTime(s.startsAt, timeZone)}
                  </label>
                )
              })}
            </div>
          </fieldset>
        </div>
        <div className="space-y-4">
          <PatientPicker value={patient} onChange={setPatient} />
          <FormField label="Reason (optional)" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        {error && (
          <div className="md:col-span-2">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        <div className="flex gap-2 md:col-span-2">
          <Button type="submit" disabled={create.isPending}>
            {create.isPending ? 'Booking…' : 'Confirm booking'}
          </Button>
          <Button variant="secondary" onClick={onCancel}>
            Close
          </Button>
        </div>
      </form>
    </Card>
  )
}
