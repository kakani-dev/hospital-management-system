import { useEffect, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { SelectField } from '../../components/ui/SelectField'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { CalendarToolbar } from '../../components/scheduling/CalendarToolbar'
import { StatusBadge } from '../../components/scheduling/StatusBadge'
import { useAppointments, useCancelAppointment, usePatientRefs, usePractitioners } from '../../lib/api/hooks'
import { addDays, dateInZone, formatDayLabel, formatTime, weekDates, zonedTimeToInstant } from '../../lib/dates'
import { can } from '../../lib/permissions'
import type { Appointment } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'
import { useCalendarParams } from './useCalendarParams'
import { useBookablePractitioners } from './useBookablePractitioners'
import { BookingPanel, type BookingDraft } from './BookingPanel'
import { Drawer } from '@tailux/components/shared/Drawer'
import type { ReturnedPatientState } from '../patients/registerReturn'

/** Calendar refresh while open (other desks book too). */
export const CALENDAR_REFRESH_MS = 30_000

export function AppointmentCalendarPage() {
  const { me } = useCurrentContext()
  const { branches, branchId, timeZone, timeZoneReady, timeZoneMissing, setBranchId } = useBranchSelection()
  const cal = useCalendarParams(timeZone, 'day')
  const [practitionerFilter, setPractitionerFilter] = useState('')
  const location = useLocation()
  const navigate = useNavigate()
  // Alt+K ({ openBooking }) or the way back from "Register new patient" ({ booking, pickedPatient }).
  const [restored] = useState(() => {
    const st = location.state as (ReturnedPatientState & { booking?: BookingDraft; openBooking?: boolean }) | null
    return st && (st.openBooking || st.booking) ? { ...st.booking, patient: st.pickedPatient ?? null } : null
  })
  const [booking, setBooking] = useState(restored !== null)
  useEffect(() => {
    if (location.state) navigate(`${location.pathname}${location.search}`, { replace: true, state: null })
  }, [location, navigate])
  const [notice, setNotice] = useState<string | null>(null)

  // Tenant-wide list for names; the branch list for the filter and the booking picker.
  const practitioners = usePractitioners()
  const bookable = useBookablePractitioners(branchId)
  const practitionerName = (id: string) => practitioners.data?.find((p) => p.id === id)?.displayName ?? 'Unknown practitioner'

  const appointments = useAppointments(
    branchId && timeZoneReady
      ? {
          branchId,
          from: zonedTimeToInstant(cal.rangeStart, '00:00', timeZone),
          to: zonedTimeToInstant(cal.rangeEnd, '00:00', timeZone),
          practitionerId: practitionerFilter || undefined,
        }
      : null,
    { refetchInterval: CALENDAR_REFRESH_MS },
  )
  const patient = usePatientRefs(appointments.data ?? [])
  const canBook = can(rolesAtBranch(me.data, branchId), 'appointments.book')

  const days = cal.view === 'week' ? weekDates(cal.date) : [cal.date]
  const byDay = new Map<string, Appointment[]>(days.map((d) => [d, []]))
  for (const a of appointments.data ?? []) byDay.get(dateInZone(a.startsAt, timeZone))?.push(a)
  for (const list of byDay.values()) list.sort((a, b) => a.startsAt.localeCompare(b.startsAt))

  const rangeLabel = cal.view === 'week' ? `${formatDayLabel(cal.rangeStart)} – ${formatDayLabel(addDays(cal.rangeEnd, -1))}` : formatDayLabel(cal.date)

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Appointments</h1>
        {canBook && !booking && (
          <Button
            data-shortcut="open-booking"
            aria-keyshortcuts="Alt+K"
            onClick={() => {
              setNotice(null)
              setBooking(true)
            }}
          >
            Book appointment
          </Button>
        )}
      </div>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        <div className="w-60">
          <SelectField label="Practitioner" value={practitionerFilter} onChange={(e) => setPractitionerFilter(e.target.value)}>
            <option value="">All practitioners</option>
            {bookable.map((p) => (
              <option key={p.id} value={p.id}>
                {p.displayName}
              </option>
            ))}
          </SelectField>
        </div>
      </div>
      <CalendarToolbar
        date={cal.date}
        view={cal.view}
        onStep={cal.step}
        onToday={cal.goToday}
        onDate={cal.setDate}
        onView={cal.setView}
        label={`${rangeLabel}${timeZoneReady ? ` · times in ${timeZone}` : ''}`}
      />
      {notice && <Alert tone="info">{notice}</Alert>}
      {booking && branchId && (
        // Mounted only while open (so closing removes it at once); the Tailux right drawer slides it in.
        <Drawer open onClose={() => setBooking(false)} title="Book appointment" closeLabel="Close booking" testId="booking-drawer" className="max-w-2xl!">
          <BookingPanel
            branchId={branchId}
            timeZone={timeZone}
            initialDate={cal.date < cal.today ? cal.today : cal.date}
            minDate={cal.today}
            practitioners={bookable}
            initial={restored ?? undefined}
            onCancel={() => setBooking(false)}
            onBooked={(appointment, label) => {
              setBooking(false)
              setNotice(label)
              cal.setDate(dateInZone(appointment.startsAt, timeZone))
            }}
          />
        </Drawer>
      )}
      <BranchNotice branchId={branchId} timeZoneMissing={timeZoneMissing} />
      {appointments.isError && <Alert tone="warning">Appointments are unavailable right now.</Alert>}
      <div
        className={`${cal.view === 'week' ? 'grid gap-3 md:grid-cols-7' : ''} transition-opacity ${appointments.isPlaceholderData ? 'opacity-60' : ''}`}
        data-testid={`calendar-${cal.view}`}
        aria-busy={appointments.isFetching}
      >
        {days.map((d) => (
          <Card key={d} className={d === cal.today ? 'ring-2 ring-primary-600 dark:ring-primary-400' : ''}>
            <section aria-label={formatDayLabel(d)} data-testid="calendar-day" data-date={d}>
              <h2 className="mb-2 text-sm font-semibold">
                {formatDayLabel(d)}
                {d === cal.today && <span className="ml-1 text-xs font-normal text-primary-600 dark:text-primary-400">today</span>}
              </h2>
              {(appointments.isPending || appointments.isPlaceholderData) && !!branchId && (byDay.get(d)?.length ?? 0) === 0 && (
                <p className="text-sm text-gray-600 dark:text-dark-200">Loading…</p>
              )}
              {!appointments.isPending && !appointments.isPlaceholderData && (byDay.get(d)?.length ?? 0) === 0 && (
                <p className="text-sm text-gray-500 dark:text-dark-300">No appointments</p>
              )}
              <ul className="space-y-2">
                {byDay.get(d)?.map((a) => {
                  const p = patient(a)
                  return (
                    <li key={a.id} data-testid="appointment" data-status={a.status} className="rounded border border-gray-200 dark:border-dark-500 p-2 text-sm">
                      <div className="flex flex-wrap items-center justify-between gap-1">
                        <span className="font-mono">
                          {formatTime(a.startsAt, timeZone)}–{formatTime(a.endsAt, timeZone)}
                        </span>
                        <StatusBadge status={a.status} />
                      </div>
                      <div className="font-medium">
                        {p === undefined ? (
                          'Loading patient…'
                        ) : p === null ? (
                          'Patient unavailable'
                        ) : (
                          <Link to={`/patients/${p.id}`} className="text-primary-600 dark:text-primary-400 underline">
                            {p.lastName}, {p.firstName}
                          </Link>
                        )}
                        {p && <span className="ml-1 font-mono text-xs text-gray-600 dark:text-dark-200">{p.mrn}</span>}
                      </div>
                      <div className="text-xs text-gray-600 dark:text-dark-200">{practitionerName(a.practitionerId)}</div>
                      {canBook && a.status === 'booked' && <CancelAppointmentButton appointment={a} />}
                    </li>
                  )
                })}
              </ul>
            </section>
          </Card>
        ))}
      </div>
    </div>
  )
}

function CancelAppointmentButton({ appointment }: { appointment: Appointment }) {
  const cancel = useCancelAppointment()
  return (
    <div className="mt-1">
      <button
        type="button"
        className="text-xs font-medium text-error underline disabled:text-gray-400 dark:text-error-lighter dark:disabled:text-dark-400"
        disabled={cancel.isPending}
        onClick={() => cancel.mutate({ id: appointment.id })}
      >
        Cancel appointment
      </button>
      {cancel.isError && (
        <p role="alert" className="text-xs text-error dark:text-error-lighter">
          Could not cancel (it may have been checked in already).
        </p>
      )}
    </div>
  )
}
