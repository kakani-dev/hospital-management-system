import { useState } from 'react'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import type { InviteLinkIssued } from '../../lib/api/types'

const formatExpiry = (iso: string, timeZone?: string) =>
  new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: timeZone ?? 'UTC' }).format(new Date(iso)) +
  (timeZone ? '' : ' UTC')

/**
 * The one-time invite link, shown ONCE right after it was issued. The same action queues an email;
 * the link is also shown here in case that message is delayed.
 */
export function InviteLinkNotice({ invite, email, timeZone }: { invite: InviteLinkIssued; email: string; timeZone?: string }) {
  const url = `${window.location.origin}${invite.path}`
  const [copied, setCopied] = useState(false)
  return (
    <div className="space-y-3" data-testid="invite-link-notice">
      <Alert tone="info">
        An email with this link is on its way to {email}. It works once, expires {formatExpiry(invite.expiresOn, timeZone)}, and is shown here only this
        once if you also need to copy it.
      </Alert>
      <div className="flex flex-wrap items-end gap-2">
        <div className="min-w-0 grow">
          <FormField label="Invite link" readOnly value={url} data-testid="invite-link-url" onFocus={(e) => e.currentTarget.select()} />
        </div>
        <Button
          variant="secondary"
          onClick={() => {
            void navigator.clipboard
              ?.writeText(url)
              .then(() => setCopied(true))
              .catch(() => setCopied(false))
          }}
        >
          {copied ? 'Copied' : 'Copy link'}
        </Button>
      </div>
    </div>
  )
}
