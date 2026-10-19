import { Table, TBody, THead, Td, Th, Tr } from '@tailux/components/ui'
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
  const { branches, branchId, timeZone, timeZoneReady, timeZoneMissing, setBranchId } = useBranchSelection()
  const cal = useCalendarParams(timeZone, 'week')
  const schedules = useSchedules(branchId)
  const practitioners = usePractitioners()
  const days = weekDates(cal.date)

  const scheduled = new Set((schedules.data ?? []).map((s) => s.practitionerId))
  const rows = (practitioners.data ?? []).filter((p) => scheduled.has(p.id))
  const unknownIds = [...scheduled].filter((id) => !rows.some((p) => p.id === id))

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Staff schedules</h1>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        <div className="flex-1">
          <CalendarToolbar
            date={cal.date}
            view="week"
            onStep={cal.step}
            onToday={cal.goToday}
            onDate={cal.setDate}
            label={`Week of ${formatDayLabel(days[0]!)}${timeZoneReady ? ` · times in ${timeZone}` : ''}`}
          />
        </div>
      </div>
      <BranchNotice branchId={branchId} timeZoneMissing={timeZoneMissing} />
      {(schedules.isError || practitioners.isError) && <Alert tone="warning">Schedules are unavailable right now.</Alert>}
      <Card>
        <div className="table-wrapper min-w-full overflow-x-auto">
          <Table hoverable className="w-full text-left text-sm rtl:text-right" data-testid="schedule-table">
            <caption className="sr-only">Working hours per practitioner for the selected week</caption>
            <THead>
              <Tr>
                <Th
                  scope="col"
                  className="bg-gray-200 font-semibold uppercase text-gray-800 dark:bg-dark-800 dark:text-dark-100 first:ltr:rounded-tl-lg last:ltr:rounded-tr-lg"
                >
                  Practitioner
                </Th>
                {days.map((d) => (
                  <Th
                    key={d}
                    scope="col"
                    className={`bg-gray-200 font-semibold uppercase text-gray-800 dark:bg-dark-800 dark:text-dark-100 first:ltr:rounded-tl-lg last:ltr:rounded-tr-lg ${d === cal.today ? 'text-primary-600! dark:text-primary-400!' : ''}`}
                  >
                    {formatDayLabel(d)}
                    {d === cal.today && <span className="sr-only"> (today)</span>}
                  </Th>
                ))}
              </Tr>
            </THead>
            <TBody>
              {(schedules.isPending || practitioners.isPending) && !!branchId && (
                <Tr>
                  <Td colSpan={8} className="py-6 text-center text-gray-600 dark:text-dark-200">
                    Loading…
                  </Td>
                </Tr>
              )}
              {[
                ...rows.map((p) => ({ id: p.id, name: p.displayName, specialty: p.specialty })),
                ...unknownIds.map((id) => ({ id, name: 'Inactive practitioner', specialty: null })),
              ].map((p) => (
                <Tr key={p.id} data-testid="schedule-row" className="border-y border-transparent border-b-gray-200 dark:border-b-dark-500">
                  <Th scope="row" className="text-left font-medium text-gray-800 dark:text-dark-100">
                    {p.name}
                    {p.specialty && <span className="block text-xs font-normal text-gray-600 dark:text-dark-200">{p.specialty}</span>}
                  </Th>
                  {days.map((d) => {
                    const blocks = schedulesOn(schedules.data ?? [], d, p.id)
                    return (
                      <Td key={d} className="align-top" data-testid="schedule-cell" data-date={d}>
                        {blocks.length === 0 ? (
                          <span className="text-gray-400 dark:text-dark-400">
                            <span aria-hidden="true">—</span>
                            <span className="sr-only">Off</span>
                          </span>
                        ) : (
                          <ul className="space-y-1">
                            {blocks.map((b) => (
                              <li key={b.id} className="rounded bg-primary-50 dark:bg-primary-500/15 px-2 py-1">
                                {hhmm(b.startTime)}–{hhmm(b.endTime)}
                                <span className="block text-xs text-gray-600 dark:text-dark-200">{b.slotMinutes}-min slots</span>
                              </li>
                            ))}
                          </ul>
                        )}
                      </Td>
                    )
                  })}
                </Tr>
              ))}
              {!schedules.isPending && !practitioners.isPending && scheduled.size === 0 && (
                <Tr>
                  <Td colSpan={8} className="py-6 text-center text-gray-600 dark:text-dark-200" data-testid="schedules-empty">
                    No schedules at this branch yet.
                  </Td>
                </Tr>
              )}
            </TBody>
          </Table>
        </div>
      </Card>
    </div>
  )
}
