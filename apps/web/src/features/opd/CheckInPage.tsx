import { useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { StatusBadge } from '../../components/scheduling/StatusBadge'
import {
  useAppointments,
  useCheckInAppointment,
  usePatientRefs,
  usePractitioners,
  useWalkIn,
} from '../../lib/api/hooks'
import { addDays, formatDayLabel, formatTime, localToday, zonedTimeToInstant } from '../../lib/dates'
import { can } from '../../lib/permissions'
import type { CheckInResult, PatientSummary } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { useBookablePractitioners } from '../scheduling/useBookablePractitioners'
import { PatientPicker } from '../patients/PatientPicker'
import { checkInErrorMessage } from './checkInErrors'

/** Reception desk: check in today's booked appointments or issue walk-in tokens. */
export function CheckInPage() {
  const { me } = useCurrentContext()
  const { branches, branchId, timeZone, timeZoneReady, setBranchId } = useBranchSelection()
  const today = localToday(new Date(), timeZone)
  const canCheckIn = can(rolesAtBranch(me.data, branchId), 'queue.checkIn')
  const [issued, setIssued] = useState<{ result: CheckInResult; name: string } | null>(null)
  const [error, setError] = useState<string | null>(null)

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

  const onIssued = (result: CheckInResult, name: string) => {
    setError(null)
    setIssued({ result, name })
  }

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Reception check-in</h1>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        <p className="text-sm text-slate-700">
          Today at this branch: <strong>{formatDayLabel(today)}</strong> ({timeZone})
        </p>
      </div>
      {!branchId && <Alert tone="warning">You do not have access to any branch in this hospital.</Alert>}
      {branchId && !canCheckIn && <Alert tone="warning">Your role at this branch cannot check patients in.</Alert>}
      <div aria-live="polite">
        {issued && (
          <div data-testid="token-issued" className="rounded-md border border-emerald-300 bg-emerald-50 p-4 text-emerald-950">
            <p className="text-sm">Checked in {issued.name}.</p>
            <p className="text-3xl font-bold">
              Token <span data-testid="token-number">{issued.result.tokenNo}</span>
            </p>
          </div>
        )}
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Today’s appointments">
          {appointments.isPending && !!branchId && <p className="text-sm text-slate-600">Loading…</p>}
          {appointments.isError && <Alert tone="warning">Appointments are unavailable right now.</Alert>}
          {!appointments.isPending && todays.length === 0 && <p className="text-sm text-slate-600">No appointments today.</p>}
          <ul className="divide-y divide-slate-100">
            {todays.map((a) => {
              const p = patient(a)
              const name = p ? `${p.firstName} ${p.lastName}` : 'patient'
              return (
                <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm" data-testid="checkin-appointment">
                  <span>
                    <span className="font-mono">{formatTime(a.startsAt, timeZone)}</span> ·{' '}
                    <strong>{p === undefined ? 'Loading…' : p === null ? 'Patient unavailable' : `${p.lastName}, ${p.firstName}`}</strong>
                    {p && <span className="ml-1 font-mono text-xs">{p.mrn}</span>}
                    <span className="block text-xs text-slate-600">{practitionerName(a.practitionerId)}</span>
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge status={a.status} />
                    {canCheckIn && a.status === 'booked' && (
                      <Button
                        className="px-3 py-1"
                        disabled={checkIn.isPending}
                        aria-label={`Check in ${p ? `${p.firstName} ${p.lastName}` : 'appointment'} at ${formatTime(a.startsAt, timeZone)}`}
                        onClick={async () => {
                          setIssued(null)
                          try {
                            onIssued(await checkIn.mutateAsync(a.id), name)
                          } catch (e) {
                            setError(checkInErrorMessage(e))
                          }
                        }}
                      >
                        Check in
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
            onSubmit={async (picked, practitionerId) => {
              setIssued(null)
              try {
                const result = await walkIn.mutateAsync({ branchId, patientId: picked.id, ...(practitionerId ? { practitionerId } : {}) })
                onIssued(result, `${picked.firstName} ${picked.lastName}`)
                return true
              } catch (e) {
                setError(checkInErrorMessage(e))
                return false
              }
            }}
          />
        )}
      </div>
    </div>
  )
}

function WalkInCard({
  practitioners,
  busy,
  onSubmit,
}: {
  practitioners: { id: string; displayName: string }[]
  busy: boolean
  onSubmit: (patient: PatientSummary, practitionerId: string) => Promise<boolean>
}) {
  const [picked, setPicked] = useState<PatientSummary | null>(null)
  const [practitionerId, setPractitionerId] = useState('')
  const [missing, setMissing] = useState(false)
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
        <PatientPicker value={picked} onChange={setPicked} label="Find walk-in patient" />
        {missing && (
          <p role="alert" className="text-sm text-red-700">
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
        <Button type="submit" disabled={busy}>
          {busy ? 'Issuing…' : 'Issue walk-in token'}
        </Button>
      </form>
    </Card>
  )
}
