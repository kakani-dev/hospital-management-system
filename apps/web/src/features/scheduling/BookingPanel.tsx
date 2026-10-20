import { useEffect, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { transientWriteMessage } from '../../lib/api/errors'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { FormField } from '../../components/ui/FormField'
import { useCreateAppointment, useSlots, useTenantCountryCode } from '../../lib/api/hooks'
import { apiClient } from '../../lib/api/client'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { formatDayLabel, formatTime } from '../../lib/dates'
import type { Appointment, PatientSummary, Practitioner, Slot } from '../../lib/api/types'
import { PatientPicker } from '../patients/PatientPicker'
import { RegisterPatientPage } from '../patients/RegisterPatientPage'
import { prefillFromTerm, type RegisterPatientState } from '../patients/registerReturn'
import { SlotPicker } from './SlotPicker'
import { joinMissing, type BookableStatus } from './useBookablePractitioners'

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
  practitionersStatus = 'ready',
  canManageSetup = false,
  onCancel,
  onBooked,
  initial,
}: {
  branchId: string
  timeZone: string
  initialDate: string
  minDate: string
  practitioners: Practitioner[]
  /** Load state of `practitioners`, so an empty list while loading isn't shown as "none". */
  practitionersStatus?: BookableStatus
  /** Tenant admin at this branch: the empty states link to practitioner and working-hours setup. */
  canManageSetup?: boolean
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
  // Inline "+ New patient": the shared register form, embedded in this drawer (slot etc. are kept).
  const [quick, setQuick] = useState<{ prefill: RegisterPatientState['prefill'] } | null>(null)
  const [focusConfirm, setFocusConfirm] = useState(0)
  const countryCode = useTenantCountryCode()
  useEffect(() => {
    if (focusConfirm) confirmRef.current?.focus()
  }, [focusConfirm])
  // Back from registration with everything filled in: Enter confirms.
  useEffect(() => {
    if (initial?.patient) confirmRef.current?.focus()
  }, [initial?.patient])
  const slots = useSlots(branchId, practitionerId, date)
  const create = useCreateAppointment()
  const missing = [!practitionerId && 'a practitioner', !slot && 'a free slot', !patient && 'a patient'].filter((m): m is string => !!m)
  const missingMessage = missing.length ? `Choose ${joinMissing(missing)}.` : null
  const noPractitioners = practitionersStatus === 'ready' && practitioners.length === 0

  const submit = async (picked: PatientSummary | null = patient) => {
    const patient = picked
    setError(null)
    setRetryable(false)
    if (!practitionerId || !slot || !patient) {
      setError(missingMessage)
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
          disabled={noPractitioners || practitionersStatus !== 'ready'}
          onChange={(e) => {
            setPractitionerId(e.target.value)
            setSlot(null)
          }}
        >
          <option value="">
            {practitionersStatus === 'loading' ? 'Loading practitioners…' : noPractitioners ? 'No practitioners available' : 'Select a practitioner…'}
          </option>
          {practitioners.map((p) => (
            <option key={p.id} value={p.id}>
              {p.displayName}
              {p.specialty ? ` (${p.specialty})` : ''}
            </option>
          ))}
        </SelectField>
        {practitionersStatus === 'error' && <Alert tone="error">Practitioners could not be loaded. Close and try again.</Alert>}
        {noPractitioners && (
          <div data-testid="no-practitioners">
            <Alert tone="warning">
              <p>No practitioner can be booked at this branch: none has current working hours here.</p>
              {canManageSetup ? (
                <p className="mt-1">
                  <Link className="font-medium underline" to="/admin/practitioners">
                    Set up practitioners
                  </Link>{' '}
                  and{' '}
                  <Link className="font-medium underline" to="/admin/working-hours">
                    add working hours
                  </Link>{' '}
                  for this branch.
                </p>
              ) : (
                <p className="mt-1">Ask a hospital admin to add practitioners and working hours for this branch.</p>
              )}
            </Alert>
          </div>
        )}
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
        <SlotPicker
          timeZone={timeZone}
          practitionerId={practitionerId}
          slots={slots}
          value={slot}
          onChange={setSlot}
          emptyHint={
            canManageSetup ? (
              <>
                Try another date, or{' '}
                <Link className="font-medium underline" to="/admin/working-hours">
                  check working hours
                </Link>
                .
              </>
            ) : (
              'Try another date or practitioner.'
            )
          }
        />
      </div>
      <div className="space-y-4">
        {quick ? (
          <RegisterPatientPage
            embedded={{
              prefill: quick.prefill,
              branchId,
              canBook: !!practitionerId && !!slot,
              onCancel: () => setQuick(null),
              onCreated: (created, action) => {
                setPatient(created)
                setQuick(null)
                if (action === 'book') void submit(created)
                else setFocusConfirm((n) => n + 1)
              },
              onUseExisting: (match) => {
                setQuick(null)
                void apiClient.patients.get(match.id).then(
                  (p) => {
                    setPatient(p)
                    setFocusConfirm((n) => n + 1)
                  },
                  () => setError('That patient record could not be opened. Search for it instead.'),
                )
              },
            }}
          />
        ) : (
          <PatientPicker
            value={patient}
            onChange={(p) => {
              setPatient(p)
              if (p) setFocusConfirm((n) => n + 1)
            }}
            showRecent
            onCreateNew={(term) => setQuick({ prefill: prefillFromTerm(term, countryCode) })}
            registerReturn={{ to: `${location.pathname}${location.search}`, state: { booking: { practitionerId, date, slot } satisfies BookingDraft } }}
          />
        )}
        <FormField label="Reason (optional)" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </div>
      {error && (
        <div className="md:col-span-2">
          {retryable ? <RetryAlert message={error} onRetry={() => void submit()} busy={create.isPending} /> : <Alert tone="error">{error}</Alert>}
        </div>
      )}
      {missingMessage && !error && (
        <p id="booking-missing" className="text-sm text-gray-600 dark:text-dark-200 md:col-span-2" data-testid="booking-missing">
          {missingMessage}
        </p>
      )}
      <div className="flex gap-2 md:col-span-2">
        <Button
          ref={confirmRef}
          type="submit"
          disabled={create.isPending || !!missingMessage || !!quick}
          aria-describedby={missingMessage && !error ? 'booking-missing' : undefined}
        >
          {create.isPending ? 'Booking…' : 'Confirm booking'}
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Close
        </Button>
      </div>
    </form>
  )
}
