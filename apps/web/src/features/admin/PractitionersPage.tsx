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
import type { Member, Practitioner } from '../../lib/api/types'
import {
  useAdminPractitioners,
  useCreatePractitioner,
  useDeletePractitioner,
  useMembers,
  useRestorePractitioner,
  useUpdatePractitioner,
} from '../../lib/api/hooks'
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
        <Drawer open onClose={() => setEditing(null)} title={`Edit ${editing.displayName}`} closeLabel="Close editing" testId="practitioner-drawer">
          <EditPractitionerForm
            practitioner={editing}
            staff={staff}
            onCancel={() => setEditing(null)}
            onSaved={(p) => {
              setEditing(null)
              setMessage({ tone: 'info', text: `${p.displayName} saved.` })
            }}
          />
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
