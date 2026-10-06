import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
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
      setMessage({ tone: 'error', text: error instanceof ApiError && error.status === 403 ? 'Only tenant admins can manage branches.' : 'Could not create the branch.' })
    }
  }

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Branches</h1>
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
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <caption className="sr-only">Branches of this hospital</caption>
          <thead className="bg-slate-50 text-left">
            <tr>
              <th scope="col" className="px-3 py-2">Code</th>
              <th scope="col" className="px-3 py-2">Name</th>
              <th scope="col" className="px-3 py-2">Time zone</th>
              <th scope="col" className="px-3 py-2">Status</th>
              <th scope="col" className="px-3 py-2"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {branches.data?.map((b) => (
              <tr key={b.id} data-testid="branch-row">
                <td className="px-3 py-2 font-mono">{b.code}</td>
                <td className="px-3 py-2">{b.name}</td>
                <td className="px-3 py-2">{b.timezone}</td>
                <td className="px-3 py-2">{b.isActive ? 'Active' : 'Inactive'}</td>
                <td className="px-3 py-2 text-right">
                  <Button
                    variant="secondary"
                    disabled={updateBranch.isPending}
                    aria-label={`${b.isActive ? 'Deactivate' : 'Activate'} ${b.name}`}
                    onClick={() => updateBranch.mutate({ id: b.id, body: { isActive: !b.isActive } })}
                  >
                    {b.isActive ? 'Deactivate' : 'Activate'}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </div>
  )
}
