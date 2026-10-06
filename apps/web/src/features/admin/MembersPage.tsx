import { useEffect, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { useAddMember, useBranches, useMembers, useUpdateMember } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { ROLES, type Role } from '../../lib/api/types'
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

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Members</h1>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Add member">
        <p className="mb-3 text-sm text-slate-600">
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
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <caption className="sr-only">Members of this hospital</caption>
          <thead className="bg-slate-50 text-left">
            <tr>
              <th scope="col" className="px-3 py-2">Email</th>
              <th scope="col" className="px-3 py-2">Role</th>
              <th scope="col" className="px-3 py-2">Branch</th>
              <th scope="col" className="px-3 py-2">Status</th>
              <th scope="col" className="px-3 py-2"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {members.data?.map((m) => {
              const self = m.userId === me.data?.userId
              return (
                <tr key={m.id} data-testid="member-row">
                  <td className="px-3 py-2">{m.email ?? m.userId}</td>
                  <td className="px-3 py-2">
                    <label className="sr-only" htmlFor={`role-${m.id}`}>
                      Role for {m.email}
                    </label>
                    <select
                      id={`role-${m.id}`}
                      className="rounded-md border border-slate-300 bg-white px-2 py-1"
                      value={m.role}
                      disabled={self || updateMember.isPending}
                      onChange={(e) => onUpdate(m.id, { role: e.target.value as Role })}
                    >
                      {ROLES.map((r) => (
                        <option key={r} value={r}>
                          {roleLabel(r)}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td className="px-3 py-2">{m.branchName ?? 'All branches'}</td>
                  <td className="px-3 py-2 capitalize">{m.status}</td>
                  <td className="px-3 py-2 text-right">
                    {!self && m.status !== 'invited' && (
                      <Button
                        variant="secondary"
                        disabled={updateMember.isPending}
                        aria-label={`${m.status === 'active' ? 'Suspend' : 'Reactivate'} ${m.email ?? 'member'}`}
                        onClick={() => onUpdate(m.id, { status: m.status === 'active' ? 'suspended' : 'active' })}
                      >
                        {m.status === 'active' ? 'Suspend' : 'Reactivate'}
                      </Button>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </Card>
    </div>
  )
}
