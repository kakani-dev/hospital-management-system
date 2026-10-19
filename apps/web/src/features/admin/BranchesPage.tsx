import { useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Badge, Checkbox } from '@tailux/components/ui'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import type { Branch, CreateBranchRequest, UpdateBranchRequest } from '../../lib/api/types'
import { useBranches, useCreateBranch, useCurrentTenant, useUpdateBranch } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { Drawer } from '@tailux/components/shared/Drawer'
import { branchEditSchema, branchSchema, type BranchEditValues, type BranchFormValues } from './adminSchemas'

const EMPTY: BranchFormValues = { code: '', name: '', useHospitalZone: true, timezone: '' }

/** Branch zone as stored: `null` override = follows the hospital zone (audit/TZ API). */
function zoneLabel(b: Branch) {
  if (b.timezoneOverride === null) return `${b.timezone} (hospital zone)`
  return b.timezoneOverride ?? b.timezone
}

export function BranchesPage() {
  const branches = useBranches()
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
  } = useForm<BranchFormValues>({ resolver: zodResolver(branchSchema), defaultValues: EMPTY })
  const useHospitalZone = useWatch({ control, name: 'useHospitalZone' }) !== false

  const onSubmit = async (values: BranchFormValues) => {
    setMessage(null)
    // Omitting `timezone` means "inherit the hospital zone" (the older API defaults it server-side).
    const body: CreateBranchRequest = values.useHospitalZone
      ? { code: values.code, name: values.name }
      : { code: values.code, name: values.name, timezone: values.timezone }
    try {
      const created = await createBranch.mutateAsync(body)
      reset({ ...EMPTY, useHospitalZone: values.useHospitalZone, timezone: values.timezone })
      setMessage({ tone: 'info', text: `Branch ${created.name} created.` })
    } catch (error) {
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
          error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_locked'
            ? `Can't change the time zone of ${b.name} while today's queue has entries.`
            : body.timezone !== undefined || body.inheritTimezone
              ? `Could not change the time zone of ${b.name}.`
              : `Could not save ${b.name}.`,
      })
      return false
    }
  }

  const inherit = (b: Branch) => void patchBranch(b, { inheritTimezone: true }, `${b.name} now uses the hospital time zone.`)

  const columns: ColumnDef<Branch, unknown>[] = [
    { id: 'code', accessorKey: 'code', header: 'Code', cell: ({ row }) => <span className="font-mono">{row.original.code}</span> },
    { id: 'name', accessorKey: 'name', header: 'Name' },
    { id: 'timezone', accessorFn: zoneLabel, header: 'Time zone' },
    {
      id: 'status',
      accessorFn: (b) => (b.isActive ? 'Active' : 'Inactive'),
      header: 'Status',
      cell: ({ row: { original: b } }) => (
        <Badge color={b.isActive ? 'success' : 'neutral'} variant="soft">
          {b.isActive ? 'Active' : 'Inactive'}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: b } }) => (
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
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Branches</h1>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Add branch">
        <form noValidate aria-label="Add branch" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-4 sm:items-start">
          <FormField label="Code" hint="e.g. north" error={errors.code?.message} {...register('code')} />
          <FormField label="Branch name" error={errors.name?.message} {...register('name')} />
          <div className="space-y-3">
            <Checkbox
              label={hospitalZone ? `Use hospital time zone (${hospitalZone})` : 'Use hospital time zone'}
              classNames={{ labelText: 'text-sm' }}
              {...register('useHospitalZone')}
            />
            {!useHospitalZone && (
              <FormField label="Time zone" hint="IANA zone, e.g. Asia/Dubai" error={errors.timezone?.message} {...register('timezone')} />
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
        {branches.isError && <Alert tone="error">Could not load branches.</Alert>}
        <DataTable
          data={branches.data ?? []}
          columns={columns}
          caption="Branches of this hospital"
          isLoading={branches.isPending}
          empty="No branches yet."
          getRowId={(b) => b.id}
          getRowProps={() => ({ 'data-testid': 'branch-row' })}
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
}: {
  branch: Branch
  hospitalZone: string | null
  busy: boolean
  onCancel: () => void
  onSubmit: (body: UpdateBranchRequest) => Promise<void>
}) {
  const hasOverride = typeof branch.timezoneOverride === 'string'
  const {
    register,
    handleSubmit,
    control,
    formState: { errors, isSubmitting },
  } = useForm<BranchEditValues>({
    resolver: zodResolver(branchEditSchema),
    defaultValues: { name: branch.name, useHospitalZone: !hasOverride, timezone: branch.timezoneOverride ?? branch.timezone ?? '' },
  })
  const followHospital = useWatch({ control, name: 'useHospitalZone' })

  const submit = (v: BranchEditValues) => {
    const body: UpdateBranchRequest = {}
    if (v.name !== branch.name) body.name = v.name
    if (v.useHospitalZone && hasOverride) body.inheritTimezone = true
    if (!v.useHospitalZone && v.timezone !== branch.timezoneOverride) body.timezone = v.timezone
    return onSubmit(body)
  }

  return (
    <form noValidate aria-label="Edit branch" onSubmit={handleSubmit(submit)} className="space-y-4">
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Code <span className="font-mono">{branch.code}</span> can't be changed.
      </p>
      <FormField label="Branch name" error={errors.name?.message} {...register('name')} />
      <Checkbox
        label={hospitalZone ? `Use hospital time zone (${hospitalZone})` : 'Use hospital time zone'}
        classNames={{ labelText: 'text-sm' }}
        {...register('useHospitalZone')}
      />
      {!followHospital && (
        <FormField label="Branch time zone" hint="IANA zone, e.g. Asia/Dubai" error={errors.timezone?.message} {...register('timezone')} />
      )}
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Booked appointments keep their instant when the zone changes, so their local times move. You will be asked to confirm.
      </p>
      <div className="flex gap-2">
        <Button type="submit" disabled={isSubmitting || busy}>
          Save branch
        </Button>
        <Button variant="secondary" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  )
}
