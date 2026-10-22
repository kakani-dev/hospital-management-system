import { useEffect, useState } from 'react'
import { useForm, type UseFormSetError } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Badge, Checkbox } from '@tailux/components/ui'
import { Drawer } from '@tailux/components/shared/Drawer'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import type { Practitioner, Schedule } from '../../lib/api/types'
import {
  useAdminPractitioners,
  useAdminSchedules,
  useCreateSchedule,
  useDeleteSchedule,
  useRestoreSchedule,
  useUpdateSchedule,
} from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { localToday } from '../../lib/dates'
import { hhmm } from '../scheduling/scheduleUtils'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { BranchNotice } from '../tenancy/BranchNotice'
import { scheduleSchema, type ScheduleFormInput, type ScheduleValues } from './adminSchemas'

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const

type Message = { tone: 'info' | 'error'; text: string }

function statusOf(s: Schedule) {
  return s.isDeleted ? 'Deleted' : s.isActive ? 'Active' : 'Inactive'
}

function scheduleError(error: unknown, action: string): string {
  const code = problemCode(error)
  if (code === 'schedule_overlap' || (error instanceof ApiError && error.status === 409))
    return 'These hours overlap another active schedule of this practitioner, including hours at another branch.'
  if (error instanceof ApiError && error.status === 403) return 'Only tenant admins can manage working hours.'
  if (error instanceof ApiError && error.status === 404) return 'This schedule (or its practitioner) no longer exists.'
  return `Could not ${action}.`
}

function applyFieldErrors(error: unknown, setError: UseFormSetError<ScheduleFormInput>) {
  for (const [field, msg] of Object.entries(fieldErrors(error))) setError(field as keyof ScheduleFormInput, { message: msg })
}

/**
 * Weekly working hours per branch (tenant_admin). Times are branch-local wall clock and "today"
 * (the default start date) is the branch's day, never the workstation's.
 */
export function WorkingHoursPage() {
  const { branches, branchId, timeZone, timeZoneReady, timeZoneMissing, setBranchId } = useBranchSelection()
  const practitioners = useAdminPractitioners()
  const schedules = useAdminSchedules(branchId)
  const create = useCreateSchedule()
  const update = useUpdateSchedule()
  const remove = useDeleteSchedule()
  const restore = useRestoreSchedule()
  const [showDeleted, setShowDeleted] = useState(false)
  const [message, setMessage] = useState<Message | null>(null)
  const [editing, setEditing] = useState<Schedule | null>(null)
  const [deleting, setDeleting] = useState<Schedule | null>(null)
  const today = timeZoneReady ? localToday(new Date(), timeZone) : ''
  const live = (practitioners.data ?? []).filter((p) => !p.isDeleted)
  const bookable = live.filter((p) => p.isActive)
  const nameOf = (id: string) => practitioners.data?.find((p) => p.id === id)?.displayName ?? 'Unknown practitioner'
  const describe = (s: Schedule) => `${nameOf(s.practitionerId)} on ${WEEKDAYS[s.weekday - 1]} ${hhmm(s.startTime)}–${hhmm(s.endTime)}`

  const form = useForm<ScheduleFormInput, unknown, ScheduleValues>({
    resolver: zodResolver(scheduleSchema),
    defaultValues: { practitionerId: '', weekday: '1', startTime: '09:00', endTime: '13:00', slotMinutes: '15', validFrom: '', validTo: '' },
  })

  // Start date defaults to the branch's today once its zone is known.
  useEffect(() => {
    if (today && !form.getValues('validFrom')) form.setValue('validFrom', today)
  }, [today, form])

  const onCreate = async (values: ScheduleValues) => {
    if (!branchId) return
    setMessage(null)
    try {
      const created = await create.mutateAsync({ ...values, branchId, validTo: values.validTo || null })
      form.reset({ ...form.getValues(), validTo: '' })
      setMessage({ tone: 'info', text: `Added ${describe(created)}.` })
    } catch (error) {
      applyFieldErrors(error, form.setError)
      setMessage({ tone: 'error', text: scheduleError(error, 'add the working hours') })
    }
  }

  const run = (s: Schedule, action: 'deactivate' | 'activate' | 'delete' | 'restore') => {
    setMessage(null)
    const done = (text: string) => () => setMessage({ tone: 'info', text })
    const failed = (e: unknown) => setMessage({ tone: 'error', text: scheduleError(e, `${action} ${describe(s)}`) })
    if (action === 'delete')
      remove.mutate(s.id, { onSuccess: done(`Deleted ${describe(s)}.`), onError: failed, onSettled: () => setDeleting(null) })
    else if (action === 'restore') restore.mutate(s.id, { onSuccess: done(`Restored ${describe(s)}.`), onError: failed })
    else update.mutate({ id: s.id, body: { isActive: action === 'activate' } }, { onSuccess: done(`${action === 'activate' ? 'Activated' : 'Deactivated'} ${describe(s)}.`), onError: failed })
  }

  const busy = update.isPending || remove.isPending || restore.isPending
  const rows = (schedules.data ?? [])
    .filter((s) => showDeleted || !s.isDeleted)
    .sort((a, b) => a.weekday - b.weekday || a.startTime.localeCompare(b.startTime) || nameOf(a.practitionerId).localeCompare(nameOf(b.practitionerId)))

  const columns: ColumnDef<Schedule, unknown>[] = [
    { id: 'practitioner', accessorFn: (s) => nameOf(s.practitionerId), header: 'Practitioner' },
    { id: 'weekday', accessorFn: (s) => s.weekday, header: 'Day', cell: ({ row }) => WEEKDAYS[row.original.weekday - 1] },
    { id: 'hours', accessorFn: (s) => s.startTime, header: 'Hours', cell: ({ row: { original: s } }) => <span className="font-mono">{hhmm(s.startTime)}–{hhmm(s.endTime)}</span> },
    { id: 'slot', accessorFn: (s) => s.slotMinutes, header: 'Slot', cell: ({ row }) => `${row.original.slotMinutes} min` },
    { id: 'valid', accessorFn: (s) => s.validFrom, header: 'Valid', cell: ({ row: { original: s } }) => (s.validTo ? `${s.validFrom} to ${s.validTo}` : `from ${s.validFrom}`) },
    {
      id: 'status',
      accessorFn: statusOf,
      header: 'Status',
      cell: ({ row: { original: s } }) => (
        <Badge color={s.isDeleted ? 'error' : s.isActive ? 'success' : 'neutral'} variant="soft">
          {statusOf(s)}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: s } }) => (
        <div className="flex justify-end gap-2">
          {s.isDeleted ? (
            <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Restore ${describe(s)}`} onClick={() => run(s, 'restore')}>
              Restore
            </Button>
          ) : (
            <>
              <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Edit ${describe(s)}`} onClick={() => setEditing(s)}>
                Edit
              </Button>
              <Button
                variant="secondary"
                className="h-8"
                disabled={busy}
                aria-label={`${s.isActive ? 'Deactivate' : 'Activate'} ${describe(s)}`}
                onClick={() => run(s, s.isActive ? 'deactivate' : 'activate')}
              >
                {s.isActive ? 'Deactivate' : 'Activate'}
              </Button>
              <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Delete ${describe(s)}`} onClick={() => setDeleting(s)}>
                Delete
              </Button>
            </>
          )}
        </div>
      ),
    },
  ]

  const errors = form.formState.errors
  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Working hours</h1>
      <div className="flex flex-wrap items-end gap-4">
        <BranchPicker branches={branches} value={branchId} onChange={setBranchId} />
        {timeZoneReady && <p className="pb-2 text-sm text-gray-600 dark:text-dark-200">Times are branch-local ({timeZone}).</p>}
      </div>
      <BranchNotice branchId={branchId} timeZoneMissing={timeZoneMissing} />
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      {branchId && (
        <Card title="Add working hours">
          <form noValidate aria-label="Add working hours" onSubmit={form.handleSubmit(onCreate)} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4 lg:items-start">
            <SelectField label="Practitioner" error={errors.practitionerId?.message} {...form.register('practitionerId')}>
              <option value="">Select a practitioner…</option>
              {bookable.map((p: Practitioner) => (
                <option key={p.id} value={p.id}>
                  {p.displayName}
                </option>
              ))}
            </SelectField>
            <SelectField label="Weekday" error={errors.weekday?.message} {...form.register('weekday')}>
              {WEEKDAYS.map((d, i) => (
                <option key={d} value={String(i + 1)}>
                  {d}
                </option>
              ))}
            </SelectField>
            <FormField label="Start time" type="time" error={errors.startTime?.message} {...form.register('startTime')} />
            <FormField label="End time" type="time" error={errors.endTime?.message} {...form.register('endTime')} />
            <FormField label="Slot length (minutes)" type="number" min={5} max={240} step={5} error={errors.slotMinutes?.message} {...form.register('slotMinutes')} />
            <FormField
              label="Valid from"
              type="date"
              hint={today ? `Branch today: ${today}` : undefined}
              error={errors.validFrom?.message}
              {...form.register('validFrom')}
            />
            <FormField label="Valid to (optional)" type="date" error={errors.validTo?.message} {...form.register('validTo')} />
            <div className="lg:pt-7">
              <Button type="submit" disabled={form.formState.isSubmitting || !timeZoneReady}>
                Add hours
              </Button>
            </div>
          </form>
        </Card>
      )}
      <Card>
        <div className="mb-3 flex justify-end">
          <Checkbox label="Show deleted" classNames={{ labelText: 'text-sm' }} checked={showDeleted} onChange={(e) => setShowDeleted(e.target.checked)} />
        </div>
        {schedules.isError && <Alert tone="error">Could not load working hours.</Alert>}
        <DataTable
          data={rows}
          columns={columns}
          caption="Weekly working hours at this branch"
          isLoading={!!branchId && schedules.isPending}
          empty="No working hours at this branch yet."
          getRowId={(s) => s.id}
          getRowProps={(row) => ({ 'data-testid': 'schedule-row', 'data-status': statusOf(row.original).toLowerCase() })}
        />
      </Card>
      {editing && (
        <Drawer open onClose={() => setEditing(null)} title="Edit working hours" closeLabel="Close editing" testId="schedule-drawer">
          <EditScheduleForm
            schedule={editing}
            practitionerName={nameOf(editing.practitionerId)}
            onCancel={() => setEditing(null)}
            onSaved={(s) => {
              setEditing(null)
              setMessage({ tone: 'info', text: `Saved ${describe(s)}.` })
            }}
          />
        </Drawer>
      )}
      <ConfirmDialog
        open={!!deleting}
        title="Delete working hours?"
        confirmLabel="Delete"
        busy={remove.isPending}
        onCancel={() => setDeleting(null)}
        onConfirm={() => deleting && run(deleting, 'delete')}
      >
        {deleting && <p>No new bookings will be offered for {describe(deleting)}. Existing appointments are kept.</p>}
      </ConfirmDialog>
    </div>
  )
}

function EditScheduleForm({
  schedule,
  practitionerName,
  onCancel,
  onSaved,
}: {
  schedule: Schedule
  practitionerName: string
  onCancel: () => void
  onSaved: (s: Schedule) => void
}) {
  const update = useUpdateSchedule()
  const [error, setError] = useState<string | null>(null)
  const form = useForm<ScheduleFormInput, unknown, ScheduleValues>({
    resolver: zodResolver(scheduleSchema),
    defaultValues: {
      practitionerId: schedule.practitionerId,
      weekday: String(schedule.weekday),
      startTime: hhmm(schedule.startTime),
      endTime: hhmm(schedule.endTime),
      slotMinutes: String(schedule.slotMinutes),
      validFrom: schedule.validFrom,
      validTo: schedule.validTo ?? '',
    },
  })
  const errors = form.formState.errors

  const onSubmit = async (v: ScheduleValues) => {
    setError(null)
    try {
      const saved = await update.mutateAsync({
        id: schedule.id,
        body: {
          weekday: v.weekday,
          startTime: v.startTime,
          endTime: v.endTime,
          slotMinutes: v.slotMinutes,
          validFrom: v.validFrom,
          ...(v.validTo ? { validTo: v.validTo } : schedule.validTo ? { clearValidTo: true } : {}),
        },
      })
      onSaved(saved)
    } catch (e) {
      applyFieldErrors(e, form.setError)
      setError(scheduleError(e, 'save the working hours'))
    }
  }

  return (
    <form noValidate aria-label="Edit working hours" onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
      <p className="text-sm text-gray-700 dark:text-dark-100">{practitionerName}</p>
      <SelectField label="Weekday" error={errors.weekday?.message} {...form.register('weekday')}>
        {WEEKDAYS.map((d, i) => (
          <option key={d} value={String(i + 1)}>
            {d}
          </option>
        ))}
      </SelectField>
      <div className="grid grid-cols-2 gap-4">
        <FormField label="Start time" type="time" error={errors.startTime?.message} {...form.register('startTime')} />
        <FormField label="End time" type="time" error={errors.endTime?.message} {...form.register('endTime')} />
      </div>
      <FormField label="Slot length (minutes)" type="number" min={5} max={240} step={5} error={errors.slotMinutes?.message} {...form.register('slotMinutes')} />
      <div className="grid grid-cols-2 gap-4">
        <FormField label="Valid from" type="date" error={errors.validFrom?.message} {...form.register('validFrom')} />
        <FormField label="Valid to (optional)" type="date" error={errors.validTo?.message} {...form.register('validTo')} />
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="flex gap-2">
        <Button type="submit" disabled={form.formState.isSubmitting}>
          Save
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  )
}
