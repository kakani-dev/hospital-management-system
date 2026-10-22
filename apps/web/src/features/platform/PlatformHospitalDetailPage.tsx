import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Badge, Textarea } from '@tailux/components/ui'
import { z } from 'zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { usePlatformTenant, useReissueAdminInvite, useSetTenantStatus } from '../../lib/api/hooks'
import { ApiError } from '../../lib/api/client'
import type { InviteLinkIssued } from '../../lib/api/types'
import { InviteLinkNotice } from '../invitations/InviteLinkNotice'
import { formatUtc, statusColor } from './platformFormat'

const emailSchema = z.object({ email: z.email({ error: 'Enter a valid email' }) })

export function PlatformHospitalDetailPage() {
  const { tenantId = '' } = useParams()
  const detail = usePlatformTenant(tenantId)
  const setStatus = useSetTenantStatus()
  const reissue = useReissueAdminInvite()
  const [dialog, setDialog] = useState<'suspended' | 'active' | null>(null)
  const [reason, setReason] = useState('')
  const [reasonError, setReasonError] = useState<string | null>(null)
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const [invite, setInvite] = useState<{ invite: InviteLinkIssued; email: string } | null>(null)
  const inviteForm = useForm<{ email: string }>({ resolver: zodResolver(emailSchema), defaultValues: { email: '' } })

  if (detail.isPending) return <p role="status">Loading…</p>
  if (detail.isError || !detail.data)
    return (
      <Alert tone="error">
        {detail.error instanceof ApiError && detail.error.status === 404 ? 'This hospital does not exist.' : 'Could not load the hospital.'}
      </Alert>
    )

  const t = detail.data.tenant
  const confirm = () => {
    if (!dialog) return
    if (reason.trim().length < 3) {
      setReasonError('Give a reason (at least 3 characters).')
      return
    }
    setStatus.mutate(
      { id: t.id, status: dialog, reason: reason.trim() },
      {
        onSuccess: () =>
          setMessage({
            tone: 'info',
            text: dialog === 'suspended' ? `${t.name} is suspended. Its staff can no longer sign in to it.` : `${t.name} is active again.`,
          }),
        onError: (e) => setMessage({ tone: 'error', text: e instanceof ApiError && e.status === 409 ? 'The status already changed. Reload.' : 'Could not change the status.' }),
        onSettled: () => {
          setDialog(null)
          setReason('')
        },
      },
    )
  }

  return (
    <div className="space-y-6">
      <nav aria-label="Breadcrumb" className="text-sm">
        <Link to="/platform" className="text-primary-600 underline dark:text-primary-400">
          Hospitals
        </Link>{' '}
        / {t.name}
      </nav>
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="flex items-center gap-3 text-xl font-semibold text-gray-800 dark:text-dark-50">
          {t.name}
          <Badge color={statusColor(t.status)} variant="soft" className="capitalize" data-testid="platform-tenant-status">
            {t.status}
          </Badge>
        </h1>
        {t.status === 'active' && (
          <Button variant="danger" onClick={() => setDialog('suspended')}>
            Suspend hospital
          </Button>
        )}
        {t.status === 'suspended' && <Button onClick={() => setDialog('active')}>Reactivate hospital</Button>}
      </div>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Details">
          <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm" data-testid="platform-tenant-details">
            <dt className="text-gray-600 dark:text-dark-200">Code</dt>
            <dd className="font-mono">{t.code}</dd>
            <dt className="text-gray-600 dark:text-dark-200">Time zone</dt>
            <dd>{t.timeZone}</dd>
            <dt className="text-gray-600 dark:text-dark-200">Branches</dt>
            <dd>{t.branchCount}</dd>
            <dt className="text-gray-600 dark:text-dark-200">Users</dt>
            <dd>{t.userCount}</dd>
            <dt className="text-gray-600 dark:text-dark-200">Open invites</dt>
            <dd>{t.pendingInvites}</dd>
            <dt className="text-gray-600 dark:text-dark-200">Created</dt>
            <dd>{formatUtc(t.createdOn)}</dd>
            {t.statusReason && (
              <>
                <dt className="text-gray-600 dark:text-dark-200">Last status reason</dt>
                <dd>{t.statusReason}</dd>
              </>
            )}
          </dl>
        </Card>
        <Card title="First admin invite">
          <p className="mb-3 text-sm text-gray-600 dark:text-dark-200">
            Email a new tenant-admin invite link (for example if the first one expired). Any earlier pending link for that email stops working.
          </p>
          {invite ? (
            <InviteLinkNotice invite={invite.invite} email={invite.email} />
          ) : (
            <form
              noValidate
              aria-label="Issue admin invite"
              className="flex flex-wrap items-end gap-3"
              onSubmit={inviteForm.handleSubmit((v) =>
                reissue.mutate(
                  { id: t.id, email: v.email },
                  {
                    onSuccess: (issued) => setInvite({ invite: issued, email: v.email }),
                    onError: () => setMessage({ tone: 'error', text: 'Could not issue the invite link.' }),
                  },
                ),
              )}
            >
              <div className="min-w-60 grow">
                <FormField label="Admin email" type="email" error={inviteForm.formState.errors.email?.message} {...inviteForm.register('email')} />
              </div>
              <Button type="submit" variant="secondary" disabled={reissue.isPending}>
                Issue invite link
              </Button>
            </form>
          )}
        </Card>
      </div>
      <Card title="Status history">
        {detail.data.history.length === 0 ? (
          <p className="text-sm text-gray-600 dark:text-dark-200">No status changes yet.</p>
        ) : (
          <ul className="divide-y divide-gray-200 text-sm dark:divide-dark-500" data-testid="platform-tenant-history">
            {detail.data.history.map((h, i) => (
              <li key={i} className="py-2">
                <span className="font-medium capitalize">
                  {h.fromStatus} → {h.toStatus}
                </span>{' '}
                · {formatUtc(h.changedOn)}
                {h.changedBy ? ` · ${h.changedBy}` : ''}
                <p className="text-gray-600 dark:text-dark-200">{h.reason}</p>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <ConfirmDialog
        open={dialog !== null}
        title={dialog === 'suspended' ? `Suspend ${t.name}?` : `Reactivate ${t.name}?`}
        confirmLabel={dialog === 'suspended' ? 'Suspend' : 'Reactivate'}
        busy={setStatus.isPending}
        onCancel={() => {
          setDialog(null)
          setReason('')
          setReasonError(null)
        }}
        onConfirm={confirm}
      >
        <div className="space-y-3">
          <p>
            {dialog === 'suspended'
              ? 'Staff of this hospital lose access on their next request. Nothing is deleted; you can reactivate it later.'
              : 'Staff regain access with their existing memberships.'}
          </p>
          <Textarea
            label="Reason"
            rows={3}
            value={reason}
            onChange={(e) => {
              setReason(e.target.value)
              setReasonError(null)
            }}
            error={reasonError ?? undefined}
          />
        </div>
      </ConfirmDialog>
    </div>
  )
}
