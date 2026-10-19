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
import type { Branch, CreateBranchRequest } from '../../lib/api/types'
import { useBranches, useCreateBranch, useCurrentTenant, useUpdateBranch } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { branchSchema, type BranchFormValues } from './adminSchemas'

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
  const [confirmInherit, setConfirmInherit] = useState<{ branch: Branch; futureBookings: number } | null>(null)
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

  const inherit = async (b: Branch, confirmFutureBookings = false) => {
    setMessage(null)
    try {
      await updateBranch.mutateAsync({ id: b.id, body: { inheritTimezone: true, ...(confirmFutureBookings ? { confirmFutureBookings } : {}) } })
      setConfirmInherit(null)
      setMessage({ tone: 'info', text: `${b.name} now uses the hospital time zone.` })
    } catch (error) {
      const problem = error instanceof ApiError ? error.problem : null
      if (error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_has_future_bookings') {
        setConfirmInherit({ branch: b, futureBookings: problem.futureBookings ?? 0 })
        return
      }
      setConfirmInherit(null)
      setMessage({
        tone: 'error',
        text:
          error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_locked'
            ? `Can't change the time zone of ${b.name} while today's queue has entries.`
            : `Could not change the time zone of ${b.name}.`,
      })
    }
  }

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
          {typeof b.timezoneOverride === 'string' && (
            <Button
              variant="secondary"
              className="h-8"
              disabled={updateBranch.isPending}
              aria-label={`Use the hospital time zone at ${b.name}`}
              onClick={() => void inherit(b)}
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
      <ConfirmDialog
        open={!!confirmInherit}
        title="Move future bookings?"
        confirmLabel="Change time zone"
        busy={updateBranch.isPending}
        onCancel={() => setConfirmInherit(null)}
        onConfirm={() => confirmInherit && void inherit(confirmInherit.branch, true)}
      >
        {confirmInherit && (
          <p>
            {confirmInherit.branch.name} has {confirmInherit.futureBookings} future booking{confirmInherit.futureBookings === 1 ? '' : 's'}. Their
            local times will follow the hospital time zone. Change it anyway?
          </p>
        )}
      </ConfirmDialog>
    </div>
  )
}
