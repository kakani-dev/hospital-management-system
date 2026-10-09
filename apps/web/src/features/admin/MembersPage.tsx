import { useEffect, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { Badge, Select } from '@tailux/components/ui'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { useAddMember, useBranches, useMembers, useUpdateMember } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { ROLES, type Member, type Role } from '../../lib/api/types'
import { memberSchema, type MemberFormValues } from './adminSchemas'
import { useMe } from '../../lib/api/hooks'

const roleLabel = (r: string) => r.replace('_', ' ')

export function MembersPage() {
  const members = useMembers()
  const branches = useBranches()
  const me = useMe()
  const addMember = useAddMember()
  const updateMember = useUpdateMember()
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const {
    register,
    handleSubmit,
    reset,
    setError,
    setValue,
    control,
    formState: { errors, isSubmitting },
  } = useForm<MemberFormValues>({ resolver: zodResolver(memberSchema), defaultValues: { email: '', role: 'receptionist', branchId: '' } })

  // tenant_admin is tenant-wide (API 400 / DB CHECK otherwise): only "All branches" is offered.
  const tenantWide = useWatch({ control, name: 'role' }) === 'tenant_admin'
  useEffect(() => {
    if (tenantWide) setValue('branchId', '')
  }, [tenantWide, setValue])

  const onSubmit = async (values: MemberFormValues) => {
    setMessage(null)
    try {
      // 202 + generic message for every outcome (no account / invited / already a member): the UI
      // must not reveal whether the email has an account, so it shows the server's text verbatim.
      const text = await addMember.mutateAsync({ email: values.email, role: values.role, branchId: values.branchId || null })
      reset({ email: '', role: values.role, branchId: values.branchId })
      setMessage({ tone: 'info', text })
    } catch (error) {
      const fields = fieldErrors(error)
      const unmapped: string[] = []
      for (const [field, text] of Object.entries(fields)) {
        if (field === 'email' || field === 'role' || field === 'branchId') setError(field, { message: text })
        else unmapped.push(text)
      }
      setMessage({
        tone: 'error',
        text: Object.keys(fields).length
          ? ['Please fix the highlighted fields.', ...unmapped].join(' ')
          : error instanceof ApiError && error.status === 403
            ? 'Only tenant admins can add members.'
            : 'Could not send the invitation.',
      })
    }
  }

  const onUpdate = (id: string, body: { role?: Role; status?: 'active' | 'suspended' }) =>
    updateMember.mutate(
      { id, body },
      {
        onError: (error) =>
          setMessage({
            tone: 'error',
            text: error instanceof ApiError && error.status === 409 ? 'You cannot change your own membership.' : 'Update failed.',
          }),
      },
    )

  const columns: ColumnDef<Member, unknown>[] = [
    { id: 'email', accessorFn: (m) => m.email ?? m.userId, header: 'Email' },
    {
      id: 'role',
      accessorKey: 'role',
      header: 'Role',
      cell: ({ row: { original: m } }) => (
        <>
          <label className="sr-only" htmlFor={`role-${m.id}`}>
            Role for {m.email}
          </label>
          <Select
            id={`role-${m.id}`}
            className="h-8 py-1 text-sm"
            value={m.role}
            disabled={m.userId === me.data?.userId || updateMember.isPending}
            onChange={(e) => onUpdate(m.id, { role: e.target.value as Role })}
          >
            {ROLES.map((r) => (
              <option key={r} value={r}>
                {roleLabel(r)}
              </option>
            ))}
          </Select>
        </>
      ),
    },
    { id: 'branch', accessorFn: (m) => m.branchName ?? 'All branches', header: 'Branch' },
    {
      id: 'status',
      accessorKey: 'status',
      header: 'Status',
      cell: ({ row: { original: m } }) => (
        <Badge color={m.status === 'active' ? 'success' : m.status === 'invited' ? 'info' : 'warning'} variant="soft" className="capitalize">
          {m.status}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: m } }) => (
        <div className="text-right">
          {m.userId !== me.data?.userId && m.status !== 'invited' && (
            <Button
              variant="secondary"
              className="h-8"
              disabled={updateMember.isPending}
              aria-label={`${m.status === 'active' ? 'Suspend' : 'Reactivate'} ${m.email ?? 'member'}`}
              onClick={() => onUpdate(m.id, { status: m.status === 'active' ? 'suspended' : 'active' })}
            >
              {m.status === 'active' ? 'Suspend' : 'Reactivate'}
            </Button>
          )}
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Members</h1>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Add member">
        <p className="mb-3 text-sm text-gray-600 dark:text-dark-200">
          People with an HMS account get an invitation and must accept it after signing in before they can access this hospital.
        </p>
        <form noValidate aria-label="Add member" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-4 sm:items-end">
          <FormField label="Email" type="email" autoComplete="off" error={errors.email?.message} {...register('email')} />
          <SelectField label="Role" error={errors.role?.message} {...register('role')}>
            {ROLES.map((r) => (
              <option key={r} value={r}>
                {roleLabel(r)}
              </option>
            ))}
          </SelectField>
          <SelectField label="Branch scope" error={errors.branchId?.message} {...register('branchId')}>
            <option value="">All branches</option>
            {!tenantWide &&
              branches.data
                ?.filter((b) => b.isActive)
                .map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
          </SelectField>
          <Button type="submit" disabled={isSubmitting}>
            Add member
          </Button>
        </form>
      </Card>
      <Card>
        {members.isError && <Alert tone="error">Could not load members.</Alert>}
        <DataTable
          data={members.data ?? []}
          columns={columns}
          caption="Members of this hospital"
          isLoading={members.isPending}
          empty="No members yet."
          getRowId={(m) => m.id}
          getRowProps={() => ({ 'data-testid': 'member-row' })}
        />
      </Card>
    </div>
  )
}
