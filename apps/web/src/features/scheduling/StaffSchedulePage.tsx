import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { CalendarToolbar } from '../../components/scheduling/CalendarToolbar'
import { usePractitioners, useSchedules } from '../../lib/api/hooks'
import { formatDayLabel, weekDates } from '../../lib/dates'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'
import { useCalendarParams } from './useCalendarParams'
import { hhmm, schedulesOn } from './scheduleUtils'

/** Weekly working hours of every practitioner at a branch (read-only; edited by admins via the API). */
export function StaffSchedulePage() {
  const { branches, branchId, timeZone, setBranchId } = useBranchSelection()
  const cal = useCalendarParams(timeZone, 'week')
  const schedules = useSchedules(branchId)
  const practitioners = usePractitioners()
  const days = weekDates(cal.date)

  const scheduled = new Set((schedules.data ?? []).map((s) => s.practitionerId))
  const rows = (practitioners.data ?? []).filter((p) => scheduled.has(p.id))
  const unknownIds = [...scheduled].filter((id) => !rows.some((p) => p.id === id))

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Staff schedules</h1>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        <div className="flex-1">
          <CalendarToolbar
            date={cal.date}
            view="week"
            onStep={cal.step}
            onToday={cal.goToday}
            onDate={cal.setDate}
            label={`Week of ${formatDayLabel(days[0]!)} · times in ${timeZone}`}
          />
        </div>
      </div>
      <BranchNotice branchId={branchId} />
      {(schedules.isError || practitioners.isError) && <Alert tone="warning">Schedules are unavailable right now.</Alert>}
      <Card>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-slate-200 text-sm" data-testid="schedule-table">
            <caption className="sr-only">Working hours per practitioner for the selected week</caption>
            <thead className="bg-slate-50 text-left">
              <tr>
                <th scope="col" className="px-3 py-2 font-semibold">
                  Practitioner
                </th>
                {days.map((d) => (
                  <th key={d} scope="col" className={`px-3 py-2 font-semibold ${d === cal.today ? 'text-brand-800' : ''}`}>
                    {formatDayLabel(d)}
                    {d === cal.today && <span className="sr-only"> (today)</span>}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {(schedules.isPending || practitioners.isPending) && !!branchId && (
                <tr>
                  <td colSpan={8} className="px-3 py-6 text-center text-slate-600">
                    Loading…
                  </td>
                </tr>
              )}
              {[...rows.map((p) => ({ id: p.id, name: p.displayName, specialty: p.specialty })), ...unknownIds.map((id) => ({ id, name: 'Inactive practitioner', specialty: null }))].map(
                (p) => (
                  <tr key={p.id} data-testid="schedule-row">
                    <th scope="row" className="px-3 py-2 text-left font-medium">
                      {p.name}
                      {p.specialty && <span className="block text-xs font-normal text-slate-600">{p.specialty}</span>}
                    </th>
                    {days.map((d) => {
                      const blocks = schedulesOn(schedules.data ?? [], d, p.id)
                      return (
                        <td key={d} className="px-3 py-2 align-top" data-testid="schedule-cell" data-date={d}>
                          {blocks.length === 0 ? (
                            <span className="text-slate-400">
                              <span aria-hidden="true">—</span>
                              <span className="sr-only">Off</span>
                            </span>
                          ) : (
                            <ul className="space-y-1">
                              {blocks.map((b) => (
                                <li key={b.id} className="rounded bg-brand-50 px-2 py-1">
                                  {hhmm(b.startTime)}–{hhmm(b.endTime)}
                                  <span className="block text-xs text-slate-600">{b.slotMinutes}-min slots</span>
                                </li>
                              ))}
                            </ul>
                          )}
                        </td>
                      )
                    })}
                  </tr>
                ),
              )}
              {!schedules.isPending && !practitioners.isPending && scheduled.size === 0 && (
                <tr>
                  <td colSpan={8} className="px-3 py-6 text-center text-slate-600" data-testid="schedules-empty">
                    No schedules at this branch yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
