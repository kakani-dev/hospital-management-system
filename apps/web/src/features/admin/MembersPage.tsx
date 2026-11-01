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
import { useAddMember, useBranches, useMembers, useRemoveMember, useResetMemberPassword, useSetMemberPassword, useUpdateMember } from '../../lib/api/hooks'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { generatePassword, isStrongEnough, PASSWORD_POLICY_TEXT } from '../../lib/passwordPolicy'
import { InviteLinksCard } from './InviteLinksCard'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { ROLES, type Member, type Role, type UpdateMemberRequest } from '../../lib/api/types'
import { memberSchema, type MemberFormValues } from './adminSchemas'
import { useMe } from '../../lib/api/hooks'

const roleLabel = (r: string) => r.replace(/_/g, ' ')

export function MembersPage({ embedded = false, hideDirectory = false }: { embedded?: boolean; hideDirectory?: boolean } = {}) {
  const members = useMembers()
  const branches = useBranches()
  const me = useMe()
  const addMember = useAddMember()
  const updateMember = useUpdateMember()
  const removeMember = useRemoveMember()
  const [removing, setRemoving] = useState<Member | null>(null)
  const resetPassword = useResetMemberPassword()
  const [resetting, setResetting] = useState<Member | null>(null)
  const setMemberPassword = useSetMemberPassword()
  const [settingFor, setSettingFor] = useState<Member | null>(null)
  const [newPassword, setNewPassword] = useState('')
  const [showNewPassword, setShowNewPassword] = useState(false)
  const [newPasswordError, setNewPasswordError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const activeBranches = branches.data?.filter((b) => b.isActive) ?? []
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

  const onUpdate = (id: string, body: UpdateMemberRequest) =>
    updateMember.mutate(
      { id, body },
      {
        onError: (error) =>
          setMessage({
            tone: 'error',
            text:
              error instanceof ApiError && error.status === 409
                ? (error.problem?.detail ?? 'You cannot change your own membership.')
                : error instanceof ApiError && error.status === 400
                  ? (Object.values(fieldErrors(error))[0] ?? 'That change is not allowed.')
                  : 'Update failed.',
          }),
      },
    )

  const onRemove = () => {
    if (!removing) return
    const m = removing
    removeMember.mutate(m.id, {
      onSuccess: () => setMessage({ tone: 'info', text: `${m.email ?? 'The member'} was removed from this hospital.` }),
      onError: (error) =>
        setMessage({
          tone: 'error',
          text: error instanceof ApiError && error.status === 409 ? (error.problem?.detail ?? 'This member cannot be removed.') : 'Could not remove the member.',
        }),
      onSettled: () => setRemoving(null),
    })
  }

  const openSetPassword = (m: Member) => {
    setNewPassword('')
    setShowNewPassword(false)
    setNewPasswordError(null)
    setCopied(false)
    setSettingFor(m)
  }

  const closeSetPassword = () => {
    setSettingFor(null)
    setNewPassword('')
    setNewPasswordError(null)
  }

  const onSetPassword = () => {
    if (!settingFor) return
    if (!isStrongEnough(newPassword)) {
      setNewPasswordError(PASSWORD_POLICY_TEXT)
      return
    }
    const m = settingFor
    setMemberPassword.mutate(
      { id: m.id, password: newPassword },
      {
        onSuccess: () => {
          setMessage({
            tone: 'info',
            text: `New password set for ${m.email ?? 'the member'}. They were signed out and must choose their own password at next sign-in. Share it with them privately.`,
          })
          closeSetPassword()
        },
        onError: (error) => {
          const text =
            error instanceof ApiError && error.status === 400
              ? PASSWORD_POLICY_TEXT
              : error instanceof ApiError && error.status === 429
                ? 'Too many password changes. Try again later.'
                : error instanceof ApiError && error.status === 409
                  ? 'You cannot set your own password here.'
                  : error instanceof ApiError && error.status === 403
                    ? 'You cannot set the password of this account.'
                    : error instanceof ApiError && error.status === 404
                      ? 'This member no longer has an active account here.'
                      : 'Could not set the password.'
          if (error instanceof ApiError && error.status === 400) setNewPasswordError(text)
          else {
            setMessage({ tone: 'error', text })
            closeSetPassword()
          }
        },
      },
    )
  }

  const onResetPassword = () => {
    if (!resetting) return
    const m = resetting
    resetPassword.mutate(m.id, {
      onSuccess: () =>
        setMessage({
          tone: 'info',
          text: `A password reset link was emailed to ${m.email ?? 'the member'}. It works once and expires in 1 hour. They were signed out.`,
        }),
      onError: (error) =>
        setMessage({
          tone: 'error',
          text:
            error instanceof ApiError && error.status === 429
              ? 'Too many password resets. Try again later.'
              : error instanceof ApiError && error.status === 409
                ? 'You cannot reset your own password here.'
                : error instanceof ApiError && error.status === 403
                  ? 'You cannot reset the password of this account.'
                  : error instanceof ApiError && error.status === 404
                    ? 'This member no longer has an active account here.'
                    : 'Could not reset the password.',
        }),
      onSettled: () => setResetting(null),
    })
  }

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
    {
      id: 'branch',
      accessorFn: (m) => m.branchName ?? 'All branches',
      header: 'Branch scope',
      cell: ({ row: { original: m } }) =>
        // tenant_admin is tenant-wide by rule; your own membership is not editable here.
        m.role === 'tenant_admin' || m.userId === me.data?.userId ? (
          <span>{m.branchName ?? 'All branches'}</span>
        ) : (
          <>
            <label className="sr-only" htmlFor={`branch-${m.id}`}>
              Branch scope for {m.email}
            </label>
            <Select
              id={`branch-${m.id}`}
              className="h-8 py-1 text-sm"
              value={m.branchId ?? ''}
              disabled={updateMember.isPending}
              onChange={(e) => onUpdate(m.id, e.target.value ? { branchId: e.target.value } : { allBranches: true })}
            >
              <option value="">All branches</option>
              {activeBranches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
              {m.branchId && !activeBranches.some((b) => b.id === m.branchId) && <option value={m.branchId}>{m.branchName ?? 'Inactive branch'}</option>}
            </Select>
          </>
        ),
    },
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
        <div className="flex justify-end gap-2">
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
          {m.userId !== me.data?.userId && m.status !== 'invited' && (
            <Button
              className="h-8"
              data-testid="member-set-password"
              aria-label={`Set new password for ${m.email ?? 'member'}`}
              disabled={setMemberPassword.isPending}
              onClick={() => openSetPassword(m)}
            >
              Set new password
            </Button>
          )}
          {m.userId !== me.data?.userId && m.status !== 'invited' && (
            <Button
              variant="ghost"
              className="h-8"
              data-testid="member-reset-password"
              aria-label={`Email reset link to ${m.email ?? 'member'}`}
              disabled={resetPassword.isPending}
              onClick={() => setResetting(m)}
            >
              Email reset link
            </Button>
          )}
          {m.userId !== me.data?.userId && (
            <Button variant="ghost" className="h-8" aria-label={`Remove ${m.email ?? 'member'}`} disabled={removeMember.isPending} onClick={() => setRemoving(m)}>
              Remove
            </Button>
          )}
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-6">
      {!embedded && <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Members</h1>}
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
      {!hideDirectory && <InviteLinksCard branches={branches.data ?? []} />}
      {!hideDirectory && (
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
      )}
      <ConfirmDialog
        open={removing !== null}
        title={`Remove ${removing?.email ?? 'member'}?`}
        confirmLabel="Remove member"
        busy={removeMember.isPending}
        onCancel={() => setRemoving(null)}
        onConfirm={onRemove}
      >
        <p>
          They lose access to this hospital{removing?.branchName ? ` (${removing.branchName})` : ''} immediately. Their account and the records they
          created are kept.
        </p>
      </ConfirmDialog>
      <ConfirmDialog
        open={settingFor !== null}
        title={`Set new password for ${settingFor?.email ?? 'member'}`}
        confirmLabel="Set password"
        busy={setMemberPassword.isPending}
        onCancel={closeSetPassword}
        onConfirm={onSetPassword}
      >
        <div className="space-y-3" data-testid="set-password-dialog">
          <p className="text-sm text-gray-600 dark:text-dark-200">
            They are signed out everywhere and must choose their own password the next time they sign in. Tell them this password privately; it
            is not emailed or shown again.
          </p>
          <label className="block text-sm font-medium text-gray-700 dark:text-dark-100" htmlFor="set-password-input">
            New password
          </label>
          <div className="flex gap-2">
            <input
              id="set-password-input"
              data-testid="set-password-input"
              type={showNewPassword ? 'text' : 'password'}
              autoComplete="new-password"
              spellCheck={false}
              className="h-9 min-w-0 flex-1 rounded-md border border-gray-300 bg-white px-3 font-mono text-sm text-gray-900 dark:border-dark-450 dark:bg-dark-900 dark:text-dark-50"
              value={newPassword}
              aria-invalid={newPasswordError ? true : undefined}
              aria-describedby="set-password-help"
              onChange={(event) => {
                setNewPassword(event.target.value)
                setNewPasswordError(null)
                setCopied(false)
              }}
            />
            <Button
              type="button"
              variant="secondary"
              className="h-9"
              data-testid="set-password-generate"
              onClick={() => {
                setNewPassword(generatePassword())
                setShowNewPassword(true)
                setNewPasswordError(null)
                setCopied(false)
              }}
            >
              Generate
            </Button>
          </div>
          <div className="flex gap-3 text-sm">
            <button
              type="button"
              className="font-medium text-primary-600 underline dark:text-primary-400"
              data-testid="set-password-toggle"
              onClick={() => setShowNewPassword((v) => !v)}
            >
              {showNewPassword ? 'Hide' : 'Show'}
            </button>
            <button
              type="button"
              className="font-medium text-primary-600 underline disabled:opacity-50 dark:text-primary-400"
              data-testid="set-password-copy"
              disabled={!newPassword}
              onClick={() => {
                void navigator.clipboard?.writeText(newPassword).then(() => setCopied(true), () => setCopied(false))
              }}
            >
              {copied ? 'Copied' : 'Copy'}
            </button>
          </div>
          <p id="set-password-help" data-testid="set-password-help" className={newPasswordError ? 'text-sm text-error-darker dark:text-error-lighter' : 'text-xs text-gray-500 dark:text-dark-300'}>
            {newPasswordError ?? PASSWORD_POLICY_TEXT}
          </p>
        </div>
      </ConfirmDialog>
      <ConfirmDialog
        open={resetting !== null}
        title={`Email a reset link to ${resetting?.email ?? 'member'}?`}
        confirmLabel="Send reset link"
        busy={resetPassword.isPending}
        onCancel={() => setResetting(null)}
        onConfirm={onResetPassword}
      >
        <p data-testid="reset-password-confirm-text">
          Their current password stops working and they are signed out. We email them a one-time link to choose a new password. You never see
          the password.
        </p>
      </ConfirmDialog>
    </div>
  )
}
