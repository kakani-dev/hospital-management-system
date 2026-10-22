import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Badge, Checkbox } from '@tailux/components/ui'
import { Drawer } from '@tailux/components/shared/Drawer'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import type { Member, Practitioner, PractitionerBranchMembership, Schedule } from '../../lib/api/types'
import {
  useAdminPractitioners,
  useBranches,
  useCreatePractitioner,
  useCreatePractitionerBranch,
  useCreateSchedule,
  useCreateScheduleOverride,
  useDeletePractitioner,
  useDeleteSchedule,
  useMembers,
  usePractitionerBranches,
  useRestorePractitioner,
  usePractitionerSchedules,
  useScheduleOverrides,
  useSchedulingSettings,
  useUpdatePractitioner,
  useUpdatePractitionerBranch,
  useUpdateSchedulingSettings,
} from '../../lib/api/hooks'
import { localToday } from '../../lib/dates'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { practitionerSchema, type PractitionerValues } from './adminSchemas'

const EMPTY: PractitionerValues = { displayName: '', specialty: '', userId: '' }

type Message = { tone: 'info' | 'error'; text: string }

function statusOf(p: Practitioner) {
  return p.isDeleted ? 'Deleted' : p.isActive ? 'Active' : 'Inactive'
}

/** Active staff accounts a practitioner can be linked to (one option per user). */
function staffOptions(members: Member[] | undefined) {
  const seen = new Map<string, Member>()
  for (const m of members ?? []) if (m.status === 'active' && !seen.has(m.userId)) seen.set(m.userId, m)
  return [...seen.values()].sort((a, b) => (a.email ?? '').localeCompare(b.email ?? ''))
}

function writeError(error: unknown, action: string): string {
  if (error instanceof ApiError && error.status === 403) return 'Only tenant admins can manage practitioners.'
  if (error instanceof ApiError && error.status === 404) return 'This practitioner no longer exists.'
  return `Could not ${action}.`
}

/** Practitioners admin (tenant_admin): add, edit, (de)activate, delete and restore. */
export function PractitionersPage() {
  const practitioners = useAdminPractitioners()
  const members = useMembers()
  const settings = useSchedulingSettings()
  const saveSettings = useUpdateSchedulingSettings()
  const create = useCreatePractitioner()
  const update = useUpdatePractitioner()
  const remove = useDeletePractitioner()
  const restore = useRestorePractitioner()
  const [showDeleted, setShowDeleted] = useState(false)
  const [message, setMessage] = useState<Message | null>(null)
  const [editing, setEditing] = useState<Practitioner | null>(null)
  const [deleting, setDeleting] = useState<Practitioner | null>(null)
  const staff = staffOptions(members.data)
  const staffLabel = (userId: string | null) => {
    if (!userId) return '—'
    const m = staff.find((s) => s.userId === userId)
    return m ? (m.displayName ?? m.email ?? 'Staff account') : 'Staff account'
  }

  const form = useForm<PractitionerValues>({ resolver: zodResolver(practitionerSchema), defaultValues: EMPTY })
  const onCreate = async (values: PractitionerValues) => {
    setMessage(null)
    try {
      const created = await create.mutateAsync({
        displayName: values.displayName,
        specialty: values.specialty || null,
        ...(values.userId ? { userId: values.userId } : {}),
      })
      form.reset(EMPTY)
      setMessage({ tone: 'info', text: `${created.displayName} added. Add working hours so patients can be booked.` })
    } catch (error) {
      for (const [field, msg] of Object.entries(fieldErrors(error))) {
        if (field in values) form.setError(field as keyof PractitionerValues, { message: msg })
      }
      setMessage({
        tone: 'error',
        text: error instanceof ApiError && error.status === 409 ? 'That staff account is already linked to another practitioner.' : writeError(error, 'add the practitioner'),
      })
    }
  }

  const toggleActive = (p: Practitioner) => {
    setMessage(null)
    update.mutate(
      { id: p.id, body: { isActive: !p.isActive } },
      {
        onSuccess: (saved) => setMessage({ tone: 'info', text: `${saved.displayName} is now ${saved.isActive ? 'active' : 'inactive'}.` }),
        onError: (e) => setMessage({ tone: 'error', text: writeError(e, `change ${p.displayName}`) }),
      },
    )
  }

  const doDelete = (p: Practitioner) => {
    setMessage(null)
    remove.mutate(p.id, {
      onSuccess: () => setMessage({ tone: 'info', text: `${p.displayName} was deleted. Turn on "Show deleted" to restore.` }),
      onError: (e) =>
        setMessage({
          tone: 'error',
          text:
            e instanceof ApiError && e.status === 409
              ? `${p.displayName} has open appointments. Cancel or reschedule them first.`
              : writeError(e, `delete ${p.displayName}`),
        }),
      onSettled: () => setDeleting(null),
    })
  }

  const doRestore = (p: Practitioner) => {
    setMessage(null)
    restore.mutate(p.id, {
      // Deleting also deactivated them (appointment.soft_delete_practitioner); restore keeps that.
      onSuccess: () => setMessage({ tone: 'info', text: `${p.displayName} was restored as inactive. Activate them to make them bookable again.` }),
      onError: (e) =>
        setMessage({
          tone: 'error',
          text: e instanceof ApiError && e.status === 409 ? `${p.displayName} can't be restored: the linked staff account is used by another practitioner.` : writeError(e, `restore ${p.displayName}`),
        }),
    })
  }

  const busy = update.isPending || remove.isPending || restore.isPending
  const rows = (practitioners.data ?? []).filter((p) => showDeleted || !p.isDeleted)

  const columns: ColumnDef<Practitioner, unknown>[] = [
    { id: 'name', accessorKey: 'displayName', header: 'Name' },
    { id: 'specialty', accessorFn: (p) => p.specialty ?? '—', header: 'Specialty' },
    { id: 'account', accessorFn: (p) => staffLabel(p.userId), header: 'Staff account' },
    {
      id: 'status',
      accessorFn: statusOf,
      header: 'Status',
      cell: ({ row: { original: p } }) => (
        <Badge color={p.isDeleted ? 'error' : p.isActive ? 'success' : 'neutral'} variant="soft">
          {statusOf(p)}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: p } }) => (
        <div className="flex justify-end gap-2">
          {p.isDeleted ? (
            <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Restore ${p.displayName}`} onClick={() => doRestore(p)}>
              Restore
            </Button>
          ) : (
            <>
              <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Edit ${p.displayName}`} onClick={() => setEditing(p)}>
                Edit
              </Button>
              <Button variant="secondary" className="h-8" disabled={busy} aria-label={`${p.isActive ? 'Deactivate' : 'Activate'} ${p.displayName}`} onClick={() => toggleActive(p)}>
                {p.isActive ? 'Deactivate' : 'Activate'}
              </Button>
              <Button variant="secondary" className="h-8" disabled={busy} aria-label={`Delete ${p.displayName}`} onClick={() => setDeleting(p)}>
                Delete
              </Button>
            </>
          )}
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Practitioners</h1>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <TravelBuffer key={settings.data?.travelBufferMinutes ?? 0} minutes={settings.data?.travelBufferMinutes ?? 0} busy={saveSettings.isPending} onSave={(minutes) => {
        setMessage(null)
        saveSettings.mutate(minutes, {
          onSuccess: () => setMessage({ tone: 'info', text: `Travel buffer is ${minutes} minutes.` }),
          onError: (e) => setMessage({ tone: 'error', text: e instanceof ApiError && e.problem?.detail ? e.problem.detail : 'Could not save the travel buffer.' }),
        })
      }} />
      <Card title="Add practitioner">
        <form noValidate aria-label="Add practitioner" onSubmit={form.handleSubmit(onCreate)} className="grid gap-4 sm:grid-cols-4 sm:items-start">
          <FormField label="Display name" hint="e.g. Dr. A. Rao" error={form.formState.errors.displayName?.message} {...form.register('displayName')} />
          <FormField label="Specialty (optional)" error={form.formState.errors.specialty?.message} {...form.register('specialty')} />
          <SelectField label="Staff account (optional)" error={form.formState.errors.userId?.message} {...form.register('userId')}>
            <option value="">Not linked</option>
            {staff.map((m) => (
              <option key={m.userId} value={m.userId}>
                {m.displayName ?? m.email ?? m.userId} ({m.role})
              </option>
            ))}
          </SelectField>
          <div className="sm:pt-7">
            <Button type="submit" disabled={form.formState.isSubmitting}>
              Add practitioner
            </Button>
          </div>
        </form>
      </Card>
      <Card>
        <div className="mb-3 flex justify-end">
          <Checkbox label="Show deleted" classNames={{ labelText: 'text-sm' }} checked={showDeleted} onChange={(e) => setShowDeleted(e.target.checked)} />
        </div>
        {practitioners.isError && <Alert tone="error">Could not load practitioners.</Alert>}
        <DataTable
          data={rows}
          columns={columns}
          caption="Practitioners of this hospital"
          isLoading={practitioners.isPending}
          empty="No practitioners yet."
          getRowId={(p) => p.id}
          getRowProps={(row) => ({ 'data-testid': 'practitioner-row', 'data-status': statusOf(row.original).toLowerCase() })}
        />
      </Card>
      {editing && (
        <Drawer open onClose={() => setEditing(null)} title={`Edit ${editing.displayName}`} closeLabel="Close editing" testId="practitioner-drawer" className="!max-w-3xl">
          <div className="space-y-8">
            <EditPractitionerForm
              practitioner={editing}
              staff={staff}
              onCancel={() => setEditing(null)}
              onSaved={(p) => {
                setEditing(null)
                setMessage({ tone: 'info', text: `${p.displayName} saved.` })
              }}
            />
            <BranchHoursEditor practitioner={editing} onMessage={setMessage} />
          </div>
        </Drawer>
      )}
      <ConfirmDialog
        open={!!deleting}
        title="Delete practitioner?"
        confirmLabel="Delete"
        busy={remove.isPending}
        onCancel={() => setDeleting(null)}
        onConfirm={() => deleting && doDelete(deleting)}
      >
        {deleting && <p>{deleting.displayName} will no longer be bookable and their working hours stop. A tenant admin can restore them later.</p>}
      </ConfirmDialog>
    </div>
  )
}

function EditPractitionerForm({
  practitioner,
  staff,
  onCancel,
  onSaved,
}: {
  practitioner: Practitioner
  staff: Member[]
  onCancel: () => void
  onSaved: (p: Practitioner) => void
}) {
  const update = useUpdatePractitioner()
  const [error, setError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    setError: setFieldError,
    formState: { errors, isSubmitting },
  } = useForm<PractitionerValues>({
    resolver: zodResolver(practitionerSchema),
    defaultValues: { displayName: practitioner.displayName, specialty: practitioner.specialty ?? '', userId: practitioner.userId ?? '' },
  })
  const linked = practitioner.userId && !staff.some((s) => s.userId === practitioner.userId)

  const onSubmit = async (values: PractitionerValues) => {
    setError(null)
    try {
      const saved = await update.mutateAsync({
        id: practitioner.id,
        body: {
          displayName: values.displayName,
          specialty: values.specialty || null,
          ...(values.userId ? (values.userId !== practitioner.userId ? { userId: values.userId } : {}) : practitioner.userId ? { unlinkUser: true } : {}),
        },
      })
      onSaved(saved)
    } catch (e) {
      for (const [field, msg] of Object.entries(fieldErrors(e))) {
        if (field in values) setFieldError(field as keyof PractitionerValues, { message: msg })
      }
      setError(e instanceof ApiError && e.status === 409 ? 'That staff account is already linked to another practitioner.' : writeError(e, 'save the practitioner'))
    }
  }

  return (
    <form noValidate aria-label="Edit practitioner" onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <FormField label="Display name" error={errors.displayName?.message} {...register('displayName')} />
      <FormField label="Specialty (optional)" error={errors.specialty?.message} {...register('specialty')} />
      <SelectField label="Staff account (optional)" error={errors.userId?.message} {...register('userId')}>
        <option value="">Not linked</option>
        {linked && <option value={practitioner.userId!}>Current account</option>}
        {staff.map((m) => (
          <option key={m.userId} value={m.userId}>
            {m.displayName ?? m.email ?? m.userId} ({m.role})
          </option>
        ))}
      </SelectField>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="flex gap-2">
        <Button type="submit" disabled={isSubmitting}>
          Save
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  )
}

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const

function detailOf(error: unknown, fallback: string) {
  return error instanceof ApiError && error.problem?.detail ? error.problem.detail : fallback
}

function TravelBuffer({ minutes, busy, onSave }: { minutes: number; busy: boolean; onSave: (minutes: number) => void }) {
  const [value, setValue] = useState(String(minutes))
  return (
    <Card title="Travel buffer">
      <form
        className="flex flex-wrap items-end gap-3"
        onSubmit={(e) => {
          e.preventDefault()
          const n = Number(value)
          if (!Number.isInteger(n) || n < 0 || n > 180) return
          onSave(n)
        }}
      >
        <FormField
          label="Minutes between branches"
          hint="0 allows back-to-back visits at different branches. Same-branch slots are unchanged."
          type="number"
          min={0}
          max={180}
          value={value}
          onChange={(e) => setValue(e.target.value)}
        />
        <Button type="submit" variant="secondary" disabled={busy}>
          Save travel buffer
        </Button>
      </form>
    </Card>
  )
}

/** Branches and weekly hours for one practitioner, on the same screen as their name. */
function BranchHoursEditor({ practitioner, onMessage }: { practitioner: Practitioner; onMessage: (m: Message) => void }) {
  const branches = useBranches()
  const memberships = usePractitionerBranches(practitioner.id)
  const schedules = usePractitionerSchedules(practitioner.id)
  const overrides = useScheduleOverrides(practitioner.id)
  const addBranch = useCreatePractitionerBranch()
  const saveBranch = useUpdatePractitionerBranch()
  const addHours = useCreateSchedule()
  const removeHours = useDeleteSchedule()
  const addLeave = useCreateScheduleOverride()
  const liveBranches = (branches.data ?? []).filter((b) => b.isActive && !b.isDeleted)
  const [branchId, setBranchId] = useState('')
  const [hourBranch, setHourBranch] = useState('')
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5, 6])
  const [start, setStart] = useState('09:00')
  const [end, setEnd] = useState('13:00')
  const [slot, setSlot] = useState('15')
  const [leaveDate, setLeaveDate] = useState('')
  const [error, setError] = useState<string | null>(null)
  const chosen = hourBranch || memberships.data?.[0]?.branchId || ''
  const zone = liveBranches.find((b) => b.id === chosen)?.timezone
  const today = zone ? localToday(new Date(), zone) : ''
  const branchName = (id: string) => liveBranches.find((b) => b.id === id)?.name ?? 'Branch'

  const onAddBranch = async () => {
    setError(null)
    if (!branchId) {
      setError('Choose a branch.')
      return
    }
    try {
      await addBranch.mutateAsync({ practitionerId: practitioner.id, branchId })
      setHourBranch(branchId)
      setBranchId('')
      onMessage({ tone: 'info', text: `${practitioner.displayName} now works at ${branchName(branchId)}.` })
    } catch (e) {
      setError(detailOf(e, 'Could not add that branch.'))
    }
  }

  const onAddHours = async () => {
    setError(null)
    if (!chosen) {
      setError('Add a branch first.')
      return
    }
    if (days.length === 0) {
      setError('Choose at least one day.')
      return
    }
    try {
      for (const weekday of days) {
        await addHours.mutateAsync({
          practitionerId: practitioner.id,
          branchId: chosen,
          weekday,
          startTime: start.slice(0, 5),
          endTime: end.slice(0, 5),
          slotMinutes: Number(slot) || 15,
          validFrom: today,
        })
      }
      onMessage({ tone: 'info', text: `Hours saved at ${branchName(chosen)}.` })
    } catch (e) {
      setError(detailOf(e, 'Could not save those hours.'))
    }
  }

  const onLeave = async () => {
    setError(null)
    if (!chosen || !leaveDate) {
      setError('Choose a branch and a date.')
      return
    }
    try {
      await addLeave.mutateAsync({ practitionerId: practitioner.id, branchId: chosen, date: leaveDate, isLeave: true })
      setLeaveDate('')
      onMessage({ tone: 'info', text: `${practitioner.displayName} is off on ${leaveDate} at ${branchName(chosen)}.` })
    } catch (e) {
      setError(detailOf(e, 'Could not mark that day off.'))
    }
  }

  const memberBranches = memberships.data ?? []
  const hours = (schedules.data ?? []).filter((s) => !s.isDeleted && s.isActive)
  const daysOff = (overrides.data ?? []).filter((o) => o.isLeave && o.isActive)

  return (
    <section className="space-y-4" aria-label="Branches and hours">
      <h3 className="text-sm font-medium text-gray-800 dark:text-dark-50">Branches and hours</h3>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="flex flex-wrap items-end gap-2">
        <SelectField label="Branch" value={branchId} onChange={(e) => setBranchId(e.target.value)}>
          <option value="">Choose</option>
          {liveBranches.filter((b) => !memberBranches.some((m) => m.branchId === b.id)).map((b) => (
            <option key={b.id} value={b.id}>{b.name}</option>
          ))}
        </SelectField>
        <Button type="button" variant="secondary" disabled={addBranch.isPending} onClick={() => void onAddBranch()}>
          Add branch
        </Button>
      </div>
      {memberBranches.map((m) => (
        <MembershipRow key={m.id} membership={m} branchName={branchName(m.branchId)} busy={saveBranch.isPending} onSave={async (body) => {
          setError(null)
          try {
            await saveBranch.mutateAsync({ id: m.id, body })
          } catch (e) {
            setError(detailOf(e, 'Could not save the branch.'))
          }
        }} />
      ))}
      {memberBranches.length > 0 && (
        <div className="space-y-3 rounded-lg border border-gray-200 p-3 dark:border-dark-500">
          <SelectField label="Hours at" value={chosen} onChange={(e) => setHourBranch(e.target.value)}>
            {memberBranches.map((m) => (
              <option key={m.branchId} value={m.branchId}>{branchName(m.branchId)}</option>
            ))}
          </SelectField>
          <div className="flex flex-wrap gap-3">
            {WEEKDAYS.map((name, i) => (
              <Checkbox
                key={name}
                label={name.slice(0, 3)}
                checked={days.includes(i + 1)}
                onChange={(e) => setDays((cur) => e.target.checked ? [...cur, i + 1].sort() : cur.filter((d) => d !== i + 1))}
              />
            ))}
          </div>
          <div className="grid gap-3 sm:grid-cols-3">
            <FormField label="Start" type="time" value={start} onChange={(e) => setStart(e.target.value)} />
            <FormField label="End" type="time" value={end} onChange={(e) => setEnd(e.target.value)} />
            <FormField label="Slot minutes" type="number" min={5} max={240} value={slot} onChange={(e) => setSlot(e.target.value)} />
          </div>
          <Button type="button" disabled={addHours.isPending} onClick={() => void onAddHours()}>
            Add hours
          </Button>
          <ul className="space-y-1 text-sm">
            {hours.filter((s) => s.branchId === chosen).map((s) => (
              <HoursRow key={s.id} schedule={s} busy={removeHours.isPending} onDelete={() => removeHours.mutate(s.id)} />
            ))}
          </ul>
          <div className="flex flex-wrap items-end gap-2">
            <FormField label="Day off" type="date" value={leaveDate} onChange={(e) => setLeaveDate(e.target.value)} />
            <Button type="button" variant="secondary" disabled={addLeave.isPending} onClick={() => void onLeave()}>
              Mark day off
            </Button>
          </div>
          {daysOff.filter((o) => o.branchId === chosen).length > 0 && (
            <p className="text-sm text-gray-600 dark:text-dark-200">
              Off: {daysOff.filter((o) => o.branchId === chosen).map((o) => o.date).join(', ')}
            </p>
          )}
        </div>
      )}
    </section>
  )
}

function MembershipRow({
  membership,
  branchName,
  busy,
  onSave,
}: {
  membership: PractitionerBranchMembership
  branchName: string
  busy: boolean
  onSave: (body: { isActive: boolean; consultationRoom: string; consultationFeeCents?: number; clearFee?: boolean }) => Promise<void>
}) {
  const [active, setActive] = useState(membership.isActive)
  const [room, setRoom] = useState(membership.consultationRoom ?? '')
  const [fee, setFee] = useState(membership.consultationFeeCents == null ? '' : String(membership.consultationFeeCents / 100))
  return (
    <div className="grid gap-2 rounded-lg border border-gray-200 p-3 sm:grid-cols-4 dark:border-dark-500">
      <p className="text-sm font-medium sm:col-span-4">{branchName}</p>
      <Checkbox label="Active" checked={active} onChange={(e) => setActive(e.target.checked)} />
      <FormField label="Room" value={room} onChange={(e) => setRoom(e.target.value)} />
      <FormField label="Fee" type="number" min={0} step="0.01" value={fee} onChange={(e) => setFee(e.target.value)} />
      <div className="sm:pt-7">
        <Button
          type="button"
          variant="secondary"
          disabled={busy}
          onClick={() => {
            const cents = fee.trim() === '' ? undefined : Math.round(Number(fee) * 100)
            void onSave({
              isActive: active,
              consultationRoom: room,
              ...(cents == null || Number.isNaN(cents) ? { clearFee: true } : { consultationFeeCents: cents }),
            })
          }}
        >
          Update branch
        </Button>
      </div>
    </div>
  )
}

function HoursRow({ schedule, busy, onDelete }: { schedule: Schedule; busy: boolean; onDelete: () => void }) {
  const label = `${WEEKDAYS[schedule.weekday - 1]} ${schedule.startTime}–${schedule.endTime}`
  return (
    <li className="flex items-center justify-between gap-2">
      <span>{label}</span>
      <Button type="button" variant="secondary" className="h-8" disabled={busy} aria-label={`Remove ${label}`} onClick={onDelete}>
        Remove
      </Button>
    </li>
  )
}

