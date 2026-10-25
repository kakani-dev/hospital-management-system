import { useState } from 'react'
import { Controller, useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { TimeZoneField } from '../../components/ui/TimeZoneField'
import { defaultZone } from '../../lib/timeZones'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Badge, Checkbox } from '@tailux/components/ui'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import type { Branch, CreateBranchRequest, UpdateBranchRequest } from '../../lib/api/types'
import { useAdminBranches, useCreateBranch, useCurrentTenant, useDeleteBranch, useRestoreBranch, useUpdateBranch } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { Drawer } from '@tailux/components/shared/Drawer'
import { branchEditSchema, branchSchema, type BranchEditValues, type BranchFormValues } from './adminSchemas'

/** A new branch follows the hospital zone; the override starts at the workstation zone or Asia/Kolkata. */
const empty = (): BranchFormValues => ({ code: '', name: '', useHospitalZone: true, timezone: defaultZone(), address: '' })

/** Branch zone as stored: `null` override = follows the hospital zone (audit/TZ API). */
function zoneLabel(b: Branch) {
  if (b.timezoneOverride === null) return `${b.timezone} (hospital zone)`
  return b.timezoneOverride ?? b.timezone
}

export function BranchesPage({
  embedded = false,
  wizard = false,
  documentPrefix = null,
  preferredBranchId = null,
  onSaved,
}: {
  embedded?: boolean
  /** Confirm the hospital's first branch instead of the branch directory. */
  wizard?: boolean
  documentPrefix?: string | null
  preferredBranchId?: string | null
  onSaved?: () => void
} = {}) {
  const [showDeleted, setShowDeleted] = useState(false)
  const branches = useAdminBranches(showDeleted)
  const deleteBranch = useDeleteBranch()
  const restoreBranch = useRestoreBranch()
  const [deleting, setDeleting] = useState<Branch | null>(null)
  const tenant = useCurrentTenant()
  const hospitalZone = tenant.data?.timeZone || null
  const createBranch = useCreateBranch()
  const updateBranch = useUpdateBranch()
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  // 409 time_zone_has_future_bookings: ask before moving booked appointments on the wall clock.
  const [confirmZone, setConfirmZone] = useState<{ branch: Branch; body: UpdateBranchRequest; done: string; futureBookings: number } | null>(null)
  const [editing, setEditing] = useState<Branch | null>(null)
  const {
    register,
    handleSubmit,
    reset,
    setError,
    control,
    formState: { errors, isSubmitting },
  } = useForm<BranchFormValues>({ resolver: zodResolver(branchSchema), defaultValues: empty() })
  const useHospitalZone = useWatch({ control, name: 'useHospitalZone' }) !== false

  const onSubmit = async (values: BranchFormValues) => {
    setMessage(null)
    // Omitting `timezone` means "inherit the hospital zone" (the older API defaults it server-side).
    const address = values.address?.trim()
    const body: CreateBranchRequest = values.useHospitalZone
      ? { code: values.code, name: values.name }
      : { code: values.code, name: values.name, timezone: values.timezone }
    if (address) body.address = address
    try {
      const created = await createBranch.mutateAsync(body)
      reset({ ...empty(), useHospitalZone: values.useHospitalZone, timezone: values.timezone })
      setMessage({ tone: 'info', text: `Branch ${created.name} created.` })
    } catch (error) {
      if (error instanceof ApiError && error.status === 409 && error.problem?.code === 'duplicate_branch_name') {
        setError('name', { message: 'A branch with this name already exists in this hospital' })
        return
      }
      if (error instanceof ApiError && error.status === 409) {
        setError('code', { message: 'A branch with this code already exists' })
        return
      }
      for (const [field, msg] of Object.entries(fieldErrors(error))) {
        if (field in values) setError(field as keyof BranchFormValues, { message: msg })
      }
      setMessage({
        tone: 'error',
        text: error instanceof ApiError && error.status === 403 ? 'Only tenant admins can manage branches.' : 'Could not create the branch.',
      })
    }
  }

  /**
   * PATCH a branch. A zone change that moves future bookings answers 409
   * time_zone_has_future_bookings: ask, then repeat with confirmFutureBookings.
   * Resolves true when saved.
   */
  const patchBranch = async (b: Branch, body: UpdateBranchRequest, done: string): Promise<boolean> => {
    setMessage(null)
    try {
      await updateBranch.mutateAsync({ id: b.id, body })
      setConfirmZone(null)
      setMessage({ tone: 'info', text: done })
      return true
    } catch (error) {
      const problem = error instanceof ApiError ? error.problem : null
      if (error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_has_future_bookings') {
        setConfirmZone({ branch: b, body, done, futureBookings: problem.futureBookings ?? 0 })
        return false
      }
      setConfirmZone(null)
      setMessage({
        tone: 'error',
        text:
          error instanceof ApiError && error.status === 409 && problem?.code === 'duplicate_branch_name'
            ? `Another branch is already called "${body.name ?? b.name}". Choose a different name.`
            : error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_locked'
            ? `Can't change the time zone of ${b.name} while today's queue has entries.`
            : body.timezone !== undefined || body.inheritTimezone
              ? `Could not change the time zone of ${b.name}.`
              : `Could not save ${b.name}.`,
      })
      return false
    }
  }

  const conflictText = (error: unknown, fallback: string) =>
    error instanceof ApiError && error.status === 409 && error.problem?.detail ? `${fallback}: ${error.problem.detail}.` : `${fallback}.`

  const onDelete = () => {
    if (!deleting) return
    const b = deleting
    deleteBranch.mutate(b.id, {
      onSuccess: () => setMessage({ tone: 'info', text: `${b.name} was deleted. Turn on “Show deleted branches” to restore it.` }),
      onError: (error) => setMessage({ tone: 'error', text: conflictText(error, `Could not delete ${b.name}`) }),
      onSettled: () => setDeleting(null),
    })
  }

  const onRestore = (b: Branch) =>
    restoreBranch.mutate(b.id, {
      onSuccess: () => setMessage({ tone: 'info', text: `${b.name} was restored${b.isActive ? '' : ' as inactive. Activate it to use it again'}.` }),
      onError: (error) => setMessage({ tone: 'error', text: conflictText(error, `Could not restore ${b.name}`) }),
    })

  const inherit = (b: Branch) => void patchBranch(b, { inheritTimezone: true }, `${b.name} now uses the hospital time zone.`)

  const columns: ColumnDef<Branch, unknown>[] = [
    { id: 'code', accessorKey: 'code', header: 'Code', cell: ({ row }) => <span className="font-mono">{row.original.code}</span> },
    { id: 'name', accessorKey: 'name', header: 'Name' },
    { id: 'timezone', accessorFn: zoneLabel, header: 'Time zone' },
    {
      id: 'status',
      accessorFn: (b) => (b.isDeleted ? 'Deleted' : b.isActive ? 'Active' : 'Inactive'),
      header: 'Status',
      cell: ({ row: { original: b } }) => (
        <Badge color={b.isDeleted ? 'error' : b.isActive ? 'success' : 'neutral'} variant="soft">
          {b.isDeleted ? 'Deleted' : b.isActive ? 'Active' : 'Inactive'}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: b } }) =>
        b.isDeleted ? (
          <div className="flex justify-end gap-2">
            <Button variant="secondary" className="h-8" disabled={restoreBranch.isPending} aria-label={`Restore ${b.name}`} onClick={() => onRestore(b)}>
              Restore
            </Button>
          </div>
        ) : (
        <div className="flex justify-end gap-2">
          <Button
            variant="secondary"
            className="h-8"
            disabled={updateBranch.isPending}
            aria-label={`Edit ${b.name}`}
            onClick={() => {
              setMessage(null)
              setEditing(b)
            }}
          >
            Edit
          </Button>
          {typeof b.timezoneOverride === 'string' && (
            <Button
              variant="secondary"
              className="h-8"
              disabled={updateBranch.isPending}
              aria-label={`Use the hospital time zone at ${b.name}`}
              onClick={() => inherit(b)}
            >
              Use hospital zone
            </Button>
          )}
          <Button
            variant="secondary"
            className="h-8"
            disabled={updateBranch.isPending}
            aria-label={`${b.isActive ? 'Deactivate' : 'Activate'} ${b.name}`}
            onClick={() => updateBranch.mutate({ id: b.id, body: { isActive: !b.isActive } })}
          >
            {b.isActive ? 'Deactivate' : 'Activate'}
          </Button>
          <Button
            variant="ghost"
            className="h-8"
            disabled={deleteBranch.isPending}
            aria-label={`Delete ${b.name}`}
            onClick={() => {
              setMessage(null)
              setDeleting(b)
            }}
          >
            Delete
          </Button>
        </div>
        ),
    },
  ]

  const live = (branches.data ?? []).filter((b) => !b.isDeleted && b.isActive)
  const preferred = live.find((b) => b.id === preferredBranchId) ?? live.find((b) => b.code === 'main') ?? live[0] ?? null
  if (wizard && branches.isPending) return <p role="status">Loading…</p>
  if (wizard && !preferred) return <Alert tone="error">This hospital has no branch yet. Add one from Branches, then come back.</Alert>
  if (wizard && preferred) {
    return (
      <div className="space-y-4">
        {message && <Alert tone={message.tone}>{message.text}</Alert>}
        <p className="text-sm text-gray-600 dark:text-dark-200">
          Document prefix <span className="font-mono" data-testid="setup-doc-prefix">{documentPrefix ?? '…'}</span>. Bills and receipts use it. It
          comes from the hospital code.
        </p>
        <EditBranchForm
          branch={preferred}
          hospitalZone={hospitalZone}
          busy={updateBranch.isPending}
          submitLabel="Save and continue"
          onCancel={() => undefined}
          hideCancel
          onSubmit={async (body) => {
            if (Object.keys(body).length === 0) {
              onSaved?.()
              return
            }
            const saved = await patchBranch(preferred, body, `${body.name ?? preferred.name} saved.`)
            if (saved) onSaved?.()
          }}
        />
        <ConfirmDialog
          open={!!confirmZone}
          title="Move future bookings?"
          confirmLabel="Change time zone"
          busy={updateBranch.isPending}
          onCancel={() => setConfirmZone(null)}
          onConfirm={() =>
            confirmZone &&
            void patchBranch(confirmZone.branch, { ...confirmZone.body, confirmFutureBookings: true }, confirmZone.done).then((ok) => {
              if (ok) onSaved?.()
            })
          }
        >
          {confirmZone && (
            <p>
              {confirmZone.branch.name} has {confirmZone.futureBookings} future booking{confirmZone.futureBookings === 1 ? '' : 's'}. Their local
              times will follow {confirmZone.body.inheritTimezone ? 'the hospital time zone' : `the new time zone (${confirmZone.body.timezone})`}. Change it
              anyway?
            </p>
          )}
        </ConfirmDialog>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {!embedded && <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Branches</h1>}
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Add branch">
        <form noValidate aria-label="Add branch" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-4 sm:items-start">
          <FormField label="Code" hint="e.g. north" error={errors.code?.message} {...register('code')} />
          <FormField label="Branch name" error={errors.name?.message} {...register('name')} />
          <FormField label="Address" hint="Optional" error={errors.address?.message} {...register('address')} />
          <div className="space-y-3">
            <Checkbox
              label={hospitalZone ? `Use hospital time zone (${hospitalZone})` : 'Use hospital time zone'}
              classNames={{ labelText: 'text-sm' }}
              {...register('useHospitalZone')}
            />
            {!useHospitalZone && (
              <Controller
                control={control}
                name="timezone"
                render={({ field }) => (
                  <TimeZoneField
                    label="Time zone"
                    hint="Search, e.g. Dubai or +04:00"
                    error={errors.timezone?.message}
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}
                    onBlur={field.onBlur}
                    ref={field.ref}
                  />
                )}
              />
            )}
          </div>
          <div className="sm:pt-7">
            <Button type="submit" disabled={isSubmitting}>
              Add branch
            </Button>
          </div>
        </form>
      </Card>
      <Card>
        <div className="mb-4">
          <Checkbox label="Show deleted branches" classNames={{ labelText: 'text-sm' }} checked={showDeleted} onChange={(e) => setShowDeleted(e.target.checked)} />
        </div>
        {branches.isError && <Alert tone="error">Could not load branches.</Alert>}
        <DataTable
          data={branches.data ?? []}
          columns={columns}
          caption="Branches of this hospital"
          isLoading={branches.isPending}
          empty="No branches yet."
          getRowId={(b) => b.id}
          isStale={branches.isPlaceholderData}
          getRowProps={(row) => ({ 'data-testid': 'branch-row', 'data-deleted': row.original.isDeleted ? 'true' : undefined })}
        />
      </Card>
      {editing && (
        <Drawer open onClose={() => setEditing(null)} title={`Edit ${editing.name}`} closeLabel="Close editing" testId="branch-drawer">
          <EditBranchForm
            branch={editing}
            hospitalZone={hospitalZone}
            busy={updateBranch.isPending}
            onCancel={() => setEditing(null)}
            onSubmit={async (body) => {
              if (Object.keys(body).length === 0) {
                setEditing(null)
                return
              }
              // On a 409 the confirm dialog takes over; the drawer closes either way.
              setEditing(null)
              await patchBranch(editing, body, `${body.name ?? editing.name} saved.`)
            }}
          />
        </Drawer>
      )}
      <ConfirmDialog
        open={deleting !== null}
        title={`Delete ${deleting?.name ?? 'branch'}?`}
        confirmLabel="Delete branch"
        busy={deleteBranch.isPending}
        onCancel={() => setDeleting(null)}
        onConfirm={onDelete}
      >
        <p>
          The branch disappears from booking, queues and the branch switcher. Its history is kept and an admin can restore it. Branches with open
          appointments or queue entries, and a hospital’s last branch, cannot be deleted.
        </p>
      </ConfirmDialog>
      <ConfirmDialog
        open={!!confirmZone}
        title="Move future bookings?"
        confirmLabel="Change time zone"
        busy={updateBranch.isPending}
        onCancel={() => setConfirmZone(null)}
        onConfirm={() => confirmZone && void patchBranch(confirmZone.branch, { ...confirmZone.body, confirmFutureBookings: true }, confirmZone.done)}
      >
        {confirmZone && (
          <p>
            {confirmZone.branch.name} has {confirmZone.futureBookings} future booking{confirmZone.futureBookings === 1 ? '' : 's'}. Their local
            times will follow {confirmZone.body.inheritTimezone ? 'the hospital time zone' : `the new time zone (${confirmZone.body.timezone})`}. Change it
            anyway?
          </p>
        )}
      </ConfirmDialog>
    </div>
  )
}

/** Edit form in the branch drawer: name, and "follow the hospital zone" or an own zone. */
function EditBranchForm({
  branch,
  hospitalZone,
  busy,
  onCancel,
  onSubmit,
  submitLabel = 'Save branch',
  hideCancel = false,
}: {
  branch: Branch
  hospitalZone: string | null
  busy: boolean
  onCancel: () => void
  onSubmit: (body: UpdateBranchRequest) => Promise<void>
  submitLabel?: string
  hideCancel?: boolean
}) {
  const hasOverride = typeof branch.timezoneOverride === 'string'
  const {
    register,
    handleSubmit,
    control,
    formState: { errors, isSubmitting },
  } = useForm<BranchEditValues>({
    resolver: zodResolver(branchEditSchema),
    defaultValues: {
      name: branch.name,
      useHospitalZone: !hasOverride,
      timezone: branch.timezoneOverride ?? (branch.timezone || defaultZone()),
      address: branch.address ?? '',
    },
  })
  const followHospital = useWatch({ control, name: 'useHospitalZone' })

  const submit = (v: BranchEditValues) => {
    const body: UpdateBranchRequest = {}
    if (v.name !== branch.name) body.name = v.name
    if (v.useHospitalZone && hasOverride) body.inheritTimezone = true
    if (!v.useHospitalZone && v.timezone !== branch.timezoneOverride) body.timezone = v.timezone
    const address = v.address?.trim()
    if (address && address !== (branch.address ?? '')) body.address = address
    return onSubmit(body)
  }

  return (
    <form noValidate aria-label="Edit branch" onSubmit={handleSubmit(submit)} className="space-y-4">
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Code <span className="font-mono">{branch.code}</span> can't be changed.
      </p>
      <FormField label="Branch name" error={errors.name?.message} {...register('name')} />
      <FormField label="Address" hint="Optional" error={errors.address?.message} {...register('address')} />
      <Checkbox
        label={hospitalZone ? `Use hospital time zone (${hospitalZone})` : 'Use hospital time zone'}
        classNames={{ labelText: 'text-sm' }}
        {...register('useHospitalZone')}
      />
      {!followHospital && (
        <Controller
          control={control}
          name="timezone"
          render={({ field }) => (
            <TimeZoneField
              label="Branch time zone"
              hint="Search, e.g. Dubai or +04:00"
              error={errors.timezone?.message}
              name={field.name}
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              ref={field.ref}
            />
          )}
        />
      )}
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Booked appointments keep their instant when the zone changes, so their local times move. You will be asked to confirm.
      </p>
      <div className="flex gap-2">
        <Button type="submit" disabled={isSubmitting || busy}>
          {submitLabel}
        </Button>
        {!hideCancel && (
          <Button variant="secondary" onClick={onCancel}>
            Cancel
          </Button>
        )}
      </div>
    </form>
  )
}
