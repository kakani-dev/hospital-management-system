import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { useAuth } from '../auth/AuthProvider'
import { useClaimInvite, useInvitePreview, useSwitchContext } from '../../lib/api/hooks'
import { ApiError, problemCode } from '../../lib/api/client'
import { PublicLayout } from '../onboarding/PublicLayout'

const roleLabel = (r: string) => r.replace(/_/g, ' ')

/**
 * /invite/:token. Shows which hospital invited whom (masked email). The invitee signs in with THAT
 * email (or creates the account first) and accepts; the server checks the email and the link.
 */
export function InvitePage() {
  const { token = '' } = useParams()
  const { session, email, signOut, refresh, resetCache, expectTenant } = useAuth()
  const navigate = useNavigate()
  const preview = useInvitePreview(token)
  const claim = useClaimInvite()
  const switchContext = useSwitchContext({ refresh, resetCache, expectTenant })
  const [error, setError] = useState<string | null>(null)

  const accept = () => {
    setError(null)
    claim.mutate(token, {
      onSuccess: (claimed) =>
        switchContext.mutate(
          { tenantId: claimed.tenantId, branchId: claimed.branchId },
          { onSettled: () => navigate('/', { replace: true, state: { joined: claimed.tenantName } }) },
        ),
      onError: (e) =>
        setError(
          problemCode(e) === 'invite_email_mismatch'
            ? `This invite is for a different email address than ${email ?? 'the one you are signed in with'}. Sign out and sign in with the invited email.`
            : e instanceof ApiError && e.status === 404
              ? 'This invite link was already used, revoked or has expired. Ask for a new one.'
              : e instanceof ApiError && e.status === 409
                ? 'Your membership in this hospital is suspended. Ask a hospital admin.'
                : 'Could not accept the invitation. Try again.',
        ),
    })
  }

  if (preview.isPending) {
    return (
      <PublicLayout title="Invitation">
        <p role="status" className="text-sm text-gray-600 dark:text-dark-200">
          Checking the invite link…
        </p>
      </PublicLayout>
    )
  }

  if (preview.isError || !preview.data) {
    return (
      <PublicLayout title="Invitation">
        <Alert tone="warning">
          {preview.error instanceof ApiError && preview.error.status === 404
            ? 'This invite link is not valid any more (already used, revoked or expired). Ask the person who invited you for a new one.'
            : 'Could not check the invite link. Try again in a moment.'}
        </Alert>
        <Link to="/login" className="text-sm font-medium text-primary-600 underline dark:text-primary-400">
          Go to sign in
        </Link>
      </PublicLayout>
    )
  }

  const p = preview.data
  const busy = claim.isPending || switchContext.isPending
  return (
    <PublicLayout title="You are invited" subtitle={p.tenantName}>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm" data-testid="invite-preview">
        <dt className="text-gray-600 dark:text-dark-200">Hospital</dt>
        <dd className="font-medium text-gray-800 dark:text-dark-50">{p.tenantName}</dd>
        <dt className="text-gray-600 dark:text-dark-200">Role</dt>
        <dd className="capitalize text-gray-800 dark:text-dark-50">{roleLabel(p.role)}</dd>
        <dt className="text-gray-600 dark:text-dark-200">Branch</dt>
        <dd className="text-gray-800 dark:text-dark-50">{p.branchName ?? 'All branches'}</dd>
        <dt className="text-gray-600 dark:text-dark-200">For</dt>
        <dd className="font-mono text-gray-800 dark:text-dark-50">{p.emailHint}</dd>
      </dl>
      {error && <Alert tone="error">{error}</Alert>}
      {session ? (
        <div className="space-y-3">
          <p className="text-sm text-gray-600 dark:text-dark-200">
            Signed in as <span className="font-medium">{email}</span>.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button onClick={accept} disabled={busy}>
              {busy ? 'Joining…' : `Join ${p.tenantName}`}
            </Button>
            <Button
              variant="secondary"
              onClick={async () => {
                await signOut()
                navigate('/login', { replace: true, state: { from: `/invite/${token}` } })
              }}
            >
              Use another account
            </Button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <p className="text-sm text-gray-600 dark:text-dark-200">Sign in with the invited email address to accept. Your account must use that email.</p>
          <Button className="w-full" onClick={() => navigate('/login', { state: { from: `/invite/${token}` } })}>
            Sign in to accept
          </Button>
        </div>
      )}
    </PublicLayout>
  )
}
