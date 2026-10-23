import { useState } from 'react'
import { Link } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { Drawer } from '@tailux/components/shared/Drawer'
import { Badge } from '@tailux/components/ui'
import { Alert } from '../../components/ui/Alert'
import { Illustration } from '../../components/ui/Illustration'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { StatusBadge } from '../../components/scheduling/StatusBadge'
import { useCheckInAppointment, usePatient, usePractitioners } from '../../lib/api/hooks'
import { dateInZone, formatDayLabel, formatTime, localToday } from '../../lib/dates'
import { can } from '../../lib/permissions'
import type { Appointment, CheckInResult } from '../../lib/api/types'
import { checkInErrorMessage } from '../opd/checkInErrors'
import { BookingPanel } from '../scheduling/BookingPanel'
import { BillingPanel } from '../billing/BillingPanel'
import { followUpInitial } from '../scheduling/followUp'
import { useBookablePractitionersState } from '../scheduling/useBookablePractitioners'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { prefetchPatientRecord } from './prefetchPatient'
import { ageOn } from './patientLabel'
import { usePatientVisits } from './usePatientVisits'
import { useWorkspace, type FollowUpIntent } from '../workspace/WorkspaceProvider'

/**
 * Patient context on the current screen (calendar, queue, search): demographics, visits at every
 * branch, and book / follow-up / check-in. Nothing here changes the route.
 */
export function PatientContextDrawer() {
  const { patient, intent, closePatient, setIntent } = useWorkspace()
  const qc = useQueryClient()
  const detail = usePatient(patient?.id ?? '')
  const visits = usePatientVisits(patient?.id ?? null)
  const { me, branches } = useCurrentContext()
  const { branchId, timeZone, timeZoneReady } = useBranchSelection()
  const bookable = useBookablePractitionersState(branchId)
  const practitioners = usePractitioners()
  const checkIn = useCheckInAppointment()
  const [notice, setNotice] = useState<string | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [issued, setIssued] = useState<{ result: CheckInResult; name: string } | null>(null)
  const [scopedId, setScopedId] = useState(patient?.id)
  if (patient?.id !== scopedId) {
    setScopedId(patient?.id)
    setNotice(null)
    setFailure(null)
    setIssued(null)
  }

  if (!patient) return null
  const branchRoles = rolesAtBranch(me.data, branchId)
  const canBook = can(branchRoles, 'appointments.book')
  const ownPractitioner = bookable.practitioners.find((p) => !!p.userId && p.userId === me.data?.userId)
  const canFollowUp = canBook || (!!ownPractitioner && can(branchRoles, 'appointments.bookFollowUp'))
  const canCheckIn = can(branchRoles, 'queue.checkIn')
  const canBill = can(branchRoles, 'billing.bill')
  const today = timeZoneReady ? localToday(new Date(), timeZone) : null
  const history = [...(visits.data ?? [])].sort((a, b) => b.startsAt.localeCompare(a.startsAt))
  const todayBooked = today
    ? history.filter((a) => a.branchId === branchId && a.status === 'booked' && dateInZone(a.startsAt, timeZone) === today)
    : []
  const anchor =
    [...history].find((v) => !ownPractitioner || v.practitionerId === ownPractitioner.id) ?? history[0]
  const branchName = (id: string) => branches.find((b) => b.id === id)?.name ?? 'Another branch'
  const practitionerName = (id: string) => practitioners.data?.find((p) => p.id === id)?.displayName ?? 'Practitioner'
  const fullName = `${patient.firstName} ${patient.lastName}`
  const booking = intent.mode === 'book'
  const billing = intent.mode === 'bill'
  const followUp: FollowUpIntent | undefined = intent.followUp

  const startBook = (asFollowUp: boolean) => {
    setFailure(null)
    setIntent({
      mode: 'book',
      followUp: asFollowUp && anchor ? { practitionerId: anchor.practitionerId, parentAppointmentId: anchor.id } : undefined,
    })
  }

  const checkInAppointment = async (appointment: Appointment) => {
    setFailure(null)
    setIssued(null)
    try {
      setIssued({ result: await checkIn.mutateAsync(appointment.id), name: fullName })
    } catch (e) {
      setFailure(checkInErrorMessage(e))
    }
  }

  const p = detail.data
  const footer = !booking && !billing ? (
    <div className="flex flex-wrap gap-2">
      {canBill && branchId && (
        <Button data-testid="context-op-consult" data-shortcut="op-consult" onClick={() => setIntent({ mode: 'bill' })}>
          OP consult
        </Button>
      )}
      {canFollowUp && anchor && (
        <Button variant="secondary" data-testid="context-follow-up" onClick={() => startBook(true)}>
          Book follow-up
        </Button>
      )}
      {canCheckIn &&
        todayBooked.map((a) => (
          <Button
            key={a.id}
            variant="secondary"
            data-testid="context-check-in"
            disabled={checkIn.isPending}
            aria-label={`Check in ${fullName} at ${formatTime(a.startsAt, timeZone)}`}
            onClick={() => void checkInAppointment(a)}
          >
            {checkIn.isPending ? 'Checking in…' : `Check in ${formatTime(a.startsAt, timeZone)}`}
          </Button>
        ))}
    </div>
  ) : undefined

  return (
    <Drawer
      open
      onClose={closePatient}
      title={billing ? 'OP consult bill' : booking ? (followUp?.parentAppointmentId ? 'Book follow-up' : 'Book appointment') : `${patient.lastName}, ${patient.firstName}`}
      closeLabel="Close patient"
      testId="patient-context"
      className={booking || billing ? 'max-w-2xl!' : 'max-w-lg!'}
      footer={footer}
    >
      {billing && branchId ? (
        <BillingPanel patientId={patient.id} branchId={branchId} onBack={() => setIntent({ mode: 'overview' })} />
      ) : booking && branchId ? (
        <BookingPanel
          key={followUp?.parentAppointmentId ? `fu-${patient.id}-${followUp.parentAppointmentId}` : `book-${patient.id}`}
          branchId={branchId}
          timeZone={timeZone}
          initialDate={today ?? localToday()}
          minDate={today ?? localToday()}
          practitioners={bookable.practitioners}
          practitionersStatus={bookable.status}
          canManageSetup={branchRoles.includes('tenant_admin')}
          canOverrideHours={can(branchRoles, 'appointments.overrideHours')}
          initial={
            followUp?.parentAppointmentId
              ? followUpInitial(patient, followUp.practitionerId, followUp.parentAppointmentId)
              : {
                  practitionerId: followUp?.practitionerId ?? undefined,
                  patient: { ...patient, dateOfBirth: p?.dateOfBirth ?? null, sex: p?.sex ?? 'unknown', registeredBranchId: p?.registeredBranchId ?? branchId },
                }
          }
          onCancel={() => setIntent({ mode: 'overview' })}
          onBooked={(_appointment, message) => {
            setNotice(message)
            setIntent({ mode: 'overview' })
          }}
        />
      ) : (
        <div className="space-y-4">
          {notice && <Alert tone="info">{notice}</Alert>}
          {failure && <Alert tone="error">{failure}</Alert>}
          {issued && (
            <div data-testid="token-issued" className="this:success flex items-center gap-3 rounded-lg border border-this/30 bg-this-darker/10 p-3 text-this-darker dark:border-this-lighter/30 dark:bg-this-lighter/10 dark:text-this-lighter">
              <Illustration name="tick" size={48} />
              <div>
                <p className="text-sm">Checked in {issued.name}.</p>
                <p className="text-2xl font-bold">
                  Token <span data-testid="token-number">{issued.result.tokenNo}</span>
                </p>
              </div>
            </div>
          )}
          {detail.isPending && <LoadingBlock rows={3} label="Loading patient" />}
          {detail.isError && <Alert tone="warning">Patient details are unavailable right now.</Alert>}
          {p && (
            <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm" data-testid="patient-context-demographics">
              <Item label="MRN" value={p.mrn} mono />
              <Item label="Age" value={ageOn(p.dateOfBirth, today ?? localToday()) ?? '—'} />
              <Item label="Date of birth" value={p.dateOfBirth ?? '—'} />
              <Item label="Sex" value={p.sex} />
              <Item label="Phone" value={p.phone ?? '—'} />
              <Item label="Branch" value={branchName(p.registeredBranchId)} />
            </dl>
          )}
          <div>
            <h3 className="mb-2 text-sm font-semibold text-gray-800 dark:text-dark-50">Visits, all branches</h3>
            {visits.isPending && <LoadingBlock rows={2} label="Loading visits" />}
            {visits.isError && <Alert tone="warning">Visit history is unavailable right now.</Alert>}
            {visits.data && history.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200">No visits in this hospital yet.</p>}
            <ul className="max-h-64 space-y-2 overflow-y-auto" data-testid="visit-history">
              {history.map((a) => (
                <li key={a.id} data-testid="visit-row" className="rounded border border-gray-200 p-2 text-sm dark:border-dark-500">
                  <div className="flex flex-wrap items-center justify-between gap-1">
                    <span>
                      {formatDayLabel(dateInZone(a.startsAt, timeZone))} · <span className="font-mono">{formatTime(a.startsAt, timeZone)}</span>
                    </span>
                    <StatusBadge status={a.status} />
                  </div>
                  <div className="text-xs text-gray-600 dark:text-dark-200">
                    {branchName(a.branchId)} · {practitionerName(a.practitionerId)}
                    {a.branchId !== p?.registeredBranchId && (
                      <Badge color="info" variant="soft" className="ml-2">
                        Other branch
                      </Badge>
                    )}
                  </div>
                  {a.reason && <div className="text-xs text-gray-700 dark:text-dark-100">{a.reason}</div>}
                </li>
              ))}
            </ul>
          </div>
          <p className="text-xs text-gray-500 dark:text-dark-300">
            <Link
              to={`/patients/${patient.id}`}
              className="font-medium text-primary-600 underline dark:text-primary-400"
              onMouseEnter={() => prefetchPatientRecord(qc, patient.id)}
              onFocus={() => prefetchPatientRecord(qc, patient.id)}
            >
              Open the full record
            </Link>{' '}
            to edit demographics.
          </p>
        </div>
      )}
    </Drawer>
  )
}

function Item({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <dt className="text-gray-500 dark:text-dark-300">{label}</dt>
      <dd className={`font-medium text-gray-800 dark:text-dark-100 ${mono ? 'font-mono' : ''}`}>{value}</dd>
    </div>
  )
}
