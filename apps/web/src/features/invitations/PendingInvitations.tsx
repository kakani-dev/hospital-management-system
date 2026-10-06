import { useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { useAcceptInvitation, useInvitations } from '../../lib/api/hooks'
import { ApiError } from '../../lib/api/client'
import type { Invitation } from '../../lib/api/types'

const roleLabel = (r: string) => r.replace(/_/g, ' ')

function formatInvitedAt(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
}

/**
 * Memberships a tenant admin created for this user. They grant nothing until the user accepts here
 * (B1: no membership without the invitee's consent). Hidden when there is nothing pending.
 */
export function PendingInvitations() {
  const invitations = useInvitations()
  const accept = useAcceptInvitation()
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)

  const onAccept = (invitation: Invitation) => {
    setMessage(null)
    accept.mutate(invitation.membershipId, {
      onSuccess: () =>
        setMessage({ tone: 'info', text: `You joined ${invitation.tenantName} as ${roleLabel(invitation.role)}. Use the hospital switcher to open it.` }),
      onError: (error) =>
        setMessage({
          tone: 'error',
          text: error instanceof ApiError && error.status === 404 ? 'This invitation is no longer available.' : 'Could not accept the invitation. Try again.',
        }),
    })
  }

  // 404 = endpoint not deployed yet; anything else is worth a quiet notice.
  const loadFailed = invitations.isError && !(invitations.error instanceof ApiError && invitations.error.status === 404)
  const items = invitations.data ?? []
  if (!message && !loadFailed && items.length === 0) return null

  return (
    <Card title="Pending invitations">
      <div className="space-y-3" data-testid="pending-invitations">
        {message && <Alert tone={message.tone}>{message.text}</Alert>}
        {loadFailed && <Alert tone="warning">Could not load your invitations.</Alert>}
        {items.length > 0 && (
          <ul className="divide-y divide-slate-100">
            {items.map((invitation) => (
              <li key={invitation.membershipId} className="flex flex-wrap items-center justify-between gap-3 py-2" data-testid="invitation-row">
                <div className="text-sm">
                  <p className="font-medium text-slate-900">{invitation.tenantName}</p>
                  <p className="text-slate-600">
                    <span className="capitalize">{roleLabel(invitation.role)}</span> ·{' '}
                    {invitation.branchId ? (invitation.branchName ?? 'One branch') : 'All branches'} · invited {formatInvitedAt(invitation.invitedAt)}
                  </p>
                </div>
                <Button
                  disabled={accept.isPending}
                  aria-label={`Accept invitation to ${invitation.tenantName} as ${roleLabel(invitation.role)}`}
                  onClick={() => onAccept(invitation)}
                >
                  Accept
                </Button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  )
}
