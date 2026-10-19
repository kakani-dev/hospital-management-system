import { useEffect, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { SelectField } from '../../components/ui/SelectField'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { StatusBadge } from '../../components/scheduling/StatusBadge'
import {
  mutationKeys,
  useAppointments,
  useCheckInAppointment,
  usePatientRefs,
  usePendingMutationIds,
  usePractitioners,
  useWalkIn,
} from '../../lib/api/hooks'
import { transientWriteMessage } from '../../lib/api/errors'
import { addDays, formatDayLabel, formatTime, localToday, zonedTimeToInstant } from '../../lib/dates'
import { can } from '../../lib/permissions'
import type { CheckInResult, PatientSummary } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'
import { useBookablePractitioners } from '../scheduling/useBookablePractitioners'
import { PatientPicker } from '../patients/PatientPicker'
import type { ReturnedPatientState } from '../patients/registerReturn'
import { checkInErrorMessage } from './checkInErrors'

/** Failed write: message, plus a retry for transient failures (writes are never auto-retried). */
interface FailedWrite {
  message: string
  retry: (() => void) | null
}

/** Reception desk: check in today's booked appointments or issue walk-in tokens. */
export function CheckInPage() {
  const { me } = useCurrentContext()
  const location = useLocation()
  const navigate = useNavigate()
  const { branches, branchId, timeZone, timeZoneReady, timeZoneMissing, setBranchId } = useBranchSelection()
  const today = localToday(new Date(), timeZone)
  const canCheckIn = can(rolesAtBranch(me.data, branchId), 'queue.checkIn')
  const [issued, setIssued] = useState<{ result: CheckInResult; name: string } | null>(null)
  const [failure, setFailure] = useState<FailedWrite | null>(null)
  const tokenRef = useRef<HTMLDivElement>(null)

  // Back from "Register new patient": the new patient arrives pre-selected in the walk-in card.
  const [returned] = useState(() => (location.state as ReturnedPatientState | null)?.pickedPatient ?? null)
  useEffect(() => {
    if ((location.state as ReturnedPatientState | null)?.pickedPatient) navigate(`${location.pathname}${location.search}`, { replace: true, state: null })
  }, [location, navigate])

  const practitioners = usePractitioners()
  const bookable = useBookablePractitioners(branchId)
  const practitionerName = (id: string | null) => (id ? (practitioners.data?.find((p) => p.id === id)?.displayName ?? '—') : 'Any doctor')

  const appointments = useAppointments(
    branchId && timeZoneReady
      ? { branchId, from: zonedTimeToInstant(today, '00:00', timeZone), to: zonedTimeToInstant(addDays(today, 1), '00:00', timeZone) }
      : null,
    { refetchInterval: 30_000 },
  )
  const todays = (appointments.data ?? []).filter((a) => a.status !== 'cancelled').sort((a, b) => a.startsAt.localeCompare(b.startsAt))
  const patient = usePatientRefs(todays)
  const checkIn = useCheckInAppointment()
  const walkIn = useWalkIn()
  const checkingIn = usePendingMutationIds<string>(mutationKeys.checkIn, (id) => id)

  // Move focus to the token so the receptionist (and a screen reader) lands on the number to call out.
  useEffect(() => {
    if (issued) tokenRef.current?.focus()
  }, [issued])

  const onIssued = (result: CheckInResult, name: string) => {
    setFailure(null)
    setIssued({ result, name })
  }

  const failed = (error: unknown, action: string, retry: () => void) => {
    const transient = transientWriteMessage(error, action)
    setFailure(transient ? { message: transient, retry } : { message: checkInErrorMessage(error), retry: null })
  }

  const checkInAppointment = async (appointmentId: string, name: string) => {
    setIssued(null)
    setFailure(null)
    try {
      onIssued(await checkIn.mutateAsync(appointmentId), name)
    } catch (e) {
      failed(e, `check in ${name}`, () => void checkInAppointment(appointmentId, name))
    }
  }

  const issueWalkIn = async (picked: PatientSummary, practitionerId: string): Promise<boolean> => {
    if (!branchId) return false
    setIssued(null)
    setFailure(null)
    const name = `${picked.firstName} ${picked.lastName}`
    try {
      const result = await walkIn.mutateAsync({ branchId, patientId: picked.id, ...(practitionerId ? { practitionerId } : {}) })
      onIssued(result, name)
      return true
    } catch (e) {
      failed(e, `issue a walk-in token for ${name}`, () => void issueWalkIn(picked, practitionerId))
      return false
    }
  }

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Reception check-in</h1>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        <p className="text-sm text-gray-700 dark:text-dark-200">
          Today at this branch: <strong>{formatDayLabel(today)}</strong>{timeZoneReady && ` (${timeZone})`}
        </p>
      </div>
      <BranchNotice branchId={branchId} timeZoneMissing={timeZoneMissing} />
      {branchId && !canCheckIn && me.data && <Alert tone="warning">Your role at this branch cannot check patients in.</Alert>}
      <div aria-live="polite">
        {issued && (
          <div ref={tokenRef} tabIndex={-1} data-testid="token-issued" className="this:success rounded-lg border border-this/30 bg-this-darker/10 p-4 text-this-darker focus:outline-2 focus:outline-this dark:border-this-lighter/30 dark:bg-this-lighter/10 dark:text-this-lighter">
            <p className="text-sm">Checked in {issued.name}.</p>
            <p className="text-3xl font-bold">
              Token <span data-testid="token-number">{issued.result.tokenNo}</span>
            </p>
          </div>
        )}
      </div>
      {failure &&
        (failure.retry ? (
          <RetryAlert message={failure.message} onRetry={failure.retry} busy={checkIn.isPending || walkIn.isPending} />
        ) : (
          <Alert tone="error">{failure.message}</Alert>
        ))}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Today’s appointments">
          {appointments.isPending && !!branchId && <p className="text-sm text-gray-600 dark:text-dark-200">Loading…</p>}
          {appointments.isError && <Alert tone="warning">Appointments are unavailable right now.</Alert>}
          {!appointments.isPending && todays.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200">No appointments today.</p>}
          <ul className="divide-y divide-gray-200 dark:divide-dark-500" data-shortcut="checkin-list">
            {todays.map((a) => {
              const p = patient(a)
              const name = p ? `${p.firstName} ${p.lastName}` : 'patient'
              const busy = checkingIn.includes(a.id)
              return (
                <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm" data-testid="checkin-appointment" aria-busy={busy}>
                  <span>
                    <span className="font-mono">{formatTime(a.startsAt, timeZone)}</span> ·{' '}
                    <strong>{p === undefined ? 'Loading…' : p === null ? 'Patient unavailable' : `${p.lastName}, ${p.firstName}`}</strong>
                    {p && <span className="ml-1 font-mono text-xs">{p.mrn}</span>}
                    <span className="block text-xs text-gray-600 dark:text-dark-200">{practitionerName(a.practitionerId)}</span>
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge status={a.status} />
                    {canCheckIn && a.status === 'booked' && (
                      <Button
                        className="px-3 py-1"
                        disabled={busy}
                        aria-label={`Check in ${p ? `${p.firstName} ${p.lastName}` : 'appointment'} at ${formatTime(a.startsAt, timeZone)}`}
                        onClick={() => void checkInAppointment(a.id, name)}
                      >
                        {busy ? 'Checking in…' : 'Check in'}
                      </Button>
                    )}
                  </span>
                </li>
              )
            })}
          </ul>
        </Card>
        {canCheckIn && branchId && (
          <WalkInCard
            practitioners={bookable}
            busy={walkIn.isPending}
            initialPatient={returned}
            registerReturnTo={`${location.pathname}${location.search}`}
            onSubmit={issueWalkIn}
          />
        )}
      </div>
    </div>
  )
}

function WalkInCard({
  practitioners,
  busy,
  initialPatient,
  registerReturnTo,
  onSubmit,
}: {
  practitioners: { id: string; displayName: string }[]
  busy: boolean
  initialPatient: PatientSummary | null
  registerReturnTo: string
  onSubmit: (patient: PatientSummary, practitionerId: string) => Promise<boolean>
}) {
  const [picked, setPicked] = useState<PatientSummary | null>(initialPatient)
  const [practitionerId, setPractitionerId] = useState('')
  const [missing, setMissing] = useState(false)
  const submitRef = useRef<HTMLButtonElement>(null)
  // Returning from registration with the new patient: Enter now issues the token.
  useEffect(() => {
    if (initialPatient) submitRef.current?.focus()
  }, [initialPatient])
  return (
    <Card title="Walk-in">
      <form
        aria-label="Walk-in check-in"
        noValidate
        className="space-y-4"
        onSubmit={async (e) => {
          e.preventDefault()
          if (!picked) {
            setMissing(true)
            return
          }
          setMissing(false)
          if (await onSubmit(picked, practitionerId)) setPicked(null)
        }}
      >
        <PatientPicker value={picked} onChange={setPicked} label="Find walk-in patient" shortcut="walk-in" registerReturn={{ to: registerReturnTo }} />
        {missing && (
          <p role="alert" className="text-sm text-error dark:text-error-lighter">
            Choose a patient first.
          </p>
        )}
        <SelectField label="Doctor (optional)" value={practitionerId} onChange={(e) => setPractitionerId(e.target.value)}>
          <option value="">Any doctor</option>
          {practitioners.map((p) => (
            <option key={p.id} value={p.id}>
              {p.displayName}
            </option>
          ))}
        </SelectField>
        <Button ref={submitRef} type="submit" disabled={busy}>
          {busy ? 'Issuing…' : 'Issue walk-in token'}
        </Button>
      </form>
    </Card>
  )
}
