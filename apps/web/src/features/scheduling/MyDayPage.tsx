import { useState } from 'react'
import { Badge } from '@tailux/components/ui'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { FormField } from '../../components/ui/FormField'
import { useBranches, useMyDay } from '../../lib/api/hooks'
import { formatTime, localToday } from '../../lib/dates'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import type { MyDayItem } from '../../lib/api/types'

/** One timeline of every branch this doctor works at today. */
export function MyDayPage() {
  const { me } = useCurrentContext()
  const branches = useBranches()
  const zone = me.data?.timeZone || undefined
  const [date, setDate] = useState('')
  const day = date || localToday(new Date(), zone)
  const mine = useMyDay(day)
  const nameOf = (id: string) => branches.data?.find((b) => b.id === id)?.name ?? 'Branch'
  const zoneOf = (id: string) => branches.data?.find((b) => b.id === id)?.timezone ?? zone

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">My day</h1>
        <FormField label="Date" type="date" value={day} onChange={(e) => setDate(e.target.value)} />
      </div>
      {mine.isError && <Alert tone="error">Could not load your day.</Alert>}
      {mine.data && !mine.data.practitionerId && <Alert tone="info">Your login is not linked to a practitioner.</Alert>}
      <Card title={mine.data?.displayName ?? 'Timeline'}>
        {mine.isPending && <p className="text-sm text-gray-500">Loading…</p>}
        {mine.data && mine.data.items.length === 0 && mine.data.practitionerId && (
          <p className="text-sm text-gray-500">Nothing scheduled.</p>
        )}
        <ol className="space-y-2" data-testid="my-day">
          {mine.data?.items.map((item, i) => (
            <li key={`${item.kind}-${item.branchId}-${item.startsAt}-${i}`} className="flex flex-wrap items-center gap-2 text-sm" data-testid="my-day-item" data-kind={item.kind}>
              <Badge variant="soft" color={item.kind === 'leave' ? 'warning' : item.kind === 'hours' ? 'neutral' : 'primary'}>
                {nameOf(item.branchId)}
              </Badge>
              <span>{line(item, zoneOf(item.branchId))}</span>
            </li>
          ))}
        </ol>
      </Card>
    </div>
  )
}

function line(item: MyDayItem, zone: string | undefined) {
  if (item.kind === 'leave') return 'Leave'
  const start = formatTime(item.startsAt, zone)
  const end = formatTime(item.endsAt, zone)
  if (item.kind === 'hours') return `Working ${start}–${end}`
  const patient = item.patient ? `${item.patient.lastName}, ${item.patient.firstName}` : 'Patient'
  return `${start}–${end} ${patient}${item.status ? ` (${item.status.replaceAll('_', ' ')})` : ''}`
}
