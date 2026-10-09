import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { Badge } from '@tailux/components/ui'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import type { Branch } from '../../lib/api/types'
import { useBranches, useCreateBranch, useUpdateBranch } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { branchSchema, type BranchFormValues } from './adminSchemas'

export function BranchesPage() {
  const branches = useBranches()
  const createBranch = useCreateBranch()
  const updateBranch = useUpdateBranch()
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<BranchFormValues>({ resolver: zodResolver(branchSchema), defaultValues: { code: '', name: '', timezone: 'Asia/Kolkata' } })

  const onSubmit = async (values: BranchFormValues) => {
    setMessage(null)
    try {
      const created = await createBranch.mutateAsync(values)
      reset({ code: '', name: '', timezone: values.timezone })
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

  const columns: ColumnDef<Branch, unknown>[] = [
    { id: 'code', accessorKey: 'code', header: 'Code', cell: ({ row }) => <span className="font-mono">{row.original.code}</span> },
    { id: 'name', accessorKey: 'name', header: 'Name' },
    { id: 'timezone', accessorKey: 'timezone', header: 'Time zone' },
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
        <div className="text-right">
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
        <form noValidate aria-label="Add branch" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-4 sm:items-end">
          <FormField label="Code" hint="e.g. north" error={errors.code?.message} {...register('code')} />
          <FormField label="Branch name" error={errors.name?.message} {...register('name')} />
          <FormField label="Time zone" error={errors.timezone?.message} {...register('timezone')} />
          <Button type="submit" disabled={isSubmitting}>
            Add branch
          </Button>
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
    </div>
  )
}
