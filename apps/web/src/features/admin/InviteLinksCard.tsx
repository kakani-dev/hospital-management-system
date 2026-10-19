import { useEffect, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Badge } from '@tailux/components/ui'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { useCreateInviteLink, useInviteLinks, useRevokeInviteLink } from '../../lib/api/hooks'
import { fieldErrors } from '../../lib/api/client'
import { ROLES, type Branch, type InviteLinkIssued } from '../../lib/api/types'
import { InviteLinkNotice } from '../invitations/InviteLinkNotice'
import { memberSchema, type MemberFormValues } from './adminSchemas'

const roleLabel = (r: string) => r.replace(/_/g, ' ')
const linkTone = (s: string) => (s === 'pending' ? 'info' : s === 'claimed' ? 'success' : 'neutral')

/**
 * Invite people who do NOT have an HMS account yet: a single-use link (7 days) the admin copies and
 * sends. The invitee signs up / signs in with that email and the link adds them to the hospital.
 */
export function InviteLinksCard({ branches, timeZone }: { branches: Branch[]; timeZone?: string }) {
  const links = useInviteLinks()
  const create = useCreateInviteLink()
  const revoke = useRevokeInviteLink()
  const [issued, setIssued] = useState<{ invite: InviteLinkIssued; email: string } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    reset,
    setValue,
    setError: setFieldError,
    control,
    formState: { errors, isSubmitting },
  } = useForm<MemberFormValues>({ resolver: zodResolver(memberSchema), defaultValues: { email: '', role: 'receptionist', branchId: '' } })
  const tenantWide = useWatch({ control, name: 'role' }) === 'tenant_admin'
  useEffect(() => {
    if (tenantWide) setValue('branchId', '')
  }, [tenantWide, setValue])
  const branchName = (id: string | null) => (id ? (branches.find((b) => b.id === id)?.name ?? 'Branch') : 'All branches')

  const onSubmit = async (values: MemberFormValues) => {
    setError(null)
    try {
      const invite = await create.mutateAsync({ email: values.email, role: values.role, branchId: values.branchId || null })
      setIssued({ invite, email: values.email })
      reset({ email: '', role: values.role, branchId: values.branchId })
    } catch (e) {
      const fields = fieldErrors(e)
      for (const [field, text] of Object.entries(fields)) {
        if (field === 'email' || field === 'role' || field === 'branchId') setFieldError(field, { message: text })
      }
      setError(Object.keys(fields).length ? 'Please fix the highlighted fields.' : 'Could not create the invite link.')
    }
  }

  return (
    <Card title="Invite links">
      <p className="mb-3 text-sm text-gray-600 dark:text-dark-200">
        For people without an HMS account. The link works once, for that email only, and expires after 7 days. No email is sent: copy it and send it
        yourself.
      </p>
      {error && <Alert tone="error">{error}</Alert>}
      <form noValidate aria-label="Create invite link" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-4 sm:items-end">
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
            branches
              .filter((b) => b.isActive)
              .map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
        </SelectField>
        <Button type="submit" variant="secondary" disabled={isSubmitting}>
          Create invite link
        </Button>
      </form>
      {issued && (
        <div className="mt-4">
          <InviteLinkNotice invite={issued.invite} email={issued.email} timeZone={timeZone} />
        </div>
      )}
      {links.isError && <Alert tone="error">Could not load invite links.</Alert>}
      {links.data && links.data.length > 0 && (
        <ul className="mt-4 divide-y divide-gray-200 text-sm dark:divide-dark-500" aria-label="Invite links">
          {links.data.map((l) => (
            <li key={l.id} className="flex flex-wrap items-center justify-between gap-3 py-2" data-testid="invite-link-row" data-status={l.status}>
              <div>
                <span className="font-medium text-gray-800 dark:text-dark-50">{l.email}</span>{' '}
                <span className="text-gray-600 dark:text-dark-200">
                  · <span className="capitalize">{roleLabel(l.role)}</span> · {branchName(l.branchId)}
                </span>
              </div>
              <div className="flex items-center gap-2">
                <Badge color={linkTone(l.status)} variant="soft" className="capitalize">
                  {l.status}
                </Badge>
                {l.status === 'pending' && (
                  <Button variant="ghost" className="h-8" aria-label={`Revoke invite link for ${l.email}`} disabled={revoke.isPending} onClick={() => revoke.mutate(l.id)}>
                    Revoke
                  </Button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
