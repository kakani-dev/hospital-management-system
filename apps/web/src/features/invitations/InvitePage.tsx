import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { FormField } from '../../components/ui/FormField'
import { useAuth } from '../auth/AuthProvider'
import { useClaimInvite, useInvitePreview, useSwitchContext } from '../../lib/api/hooks'
import { apiClient, ApiError, problemCode } from '../../lib/api/client'
import { PublicLayout } from '../onboarding/PublicLayout'

const roleLabel = (r: string) => r.replace(/_/g, ' ')

/**
 * /invite/:token. Shows which hospital invited whom (masked email). A person with no account asks
 * for a one-time code (emailed by the identity outbox), then chooses their own password. Someone
 * who already has a password can sign in instead. The server checks the email when the link is claimed.
 */
export function InvitePage() {
  const { token = '' } = useParams()
  const { session, email, signOut, signInWithTokenHash, setPassword, refresh, resetCache, expectTenant } = useAuth()
  const navigate = useNavigate()
  const preview = useInvitePreview(token)
  const claim = useClaimInvite()
  const switchContext = useSwitchContext({ refresh, resetCache, expectTenant })
  const [error, setError] = useState<string | null>(null)
  const [codeSent, setCodeSent] = useState(() => readCodeFromHash().length === 6)
  const submitRef = useRef<(value: string) => Promise<void>>(async () => {})
  useEffect(() => {
    const fromHash = readCodeFromHash()
    if (!fromHash || session || !preview.data) return
    window.history.replaceState(null, '', window.location.pathname + window.location.search)
    void submitRef.current(fromHash)
  }, [session, preview.data])
  const [code, setCode] = useState(() => readCodeFromHash())
  const [password, setPasswordValue] = useState('')
  const [sending, setSending] = useState(false)
  const [signingIn, setSigningIn] = useState(false)

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

  const requestCode = async () => {
    setError(null)
    setSending(true)
    try {
      await apiClient.publicApi.requestInviteSignInCode(token)
      setCodeSent(true)
    } catch (e) {
      setError(
        e instanceof ApiError && e.status === 429
          ? 'Too many sign-in codes were sent. Try again later.'
          : e instanceof ApiError && e.status === 404
            ? 'This invite link was already used, revoked or has expired. Ask for a new one.'
            : 'Could not send a sign-in code. Try again.',
      )
    } finally {
      setSending(false)
    }
  }

  const submitCode = async (value: string) => {
    setError(null)
    setSigningIn(true)
    try {
      const proof = await apiClient.publicApi.exchangeInviteSignInCode(token, value)
      const result = await signInWithTokenHash(proof.tokenHash)
      if (result.error) setError(result.error)
      if (window.location.hash) window.history.replaceState(null, '', window.location.pathname + window.location.search)
    } catch (e) {
      setError(
        e instanceof ApiError && (e.status === 401 || e.status === 404)
          ? 'That code is not valid. Request a new one.'
          : 'Could not sign in with that code. Try again.',
      )
    } finally {
      setSigningIn(false)
    }
  }
  submitRef.current = submitCode

  const savePassword = async () => {
    setError(null)
    if (password.length < 8) {
      setError('Password must be at least 8 characters.')
      return
    }
    setSigningIn(true)
    try {
      const result = await setPassword(password)
      if (result.error) setError(result.error)
      setPasswordValue('')
    } finally {
      setSigningIn(false)
    }
  }

  const p = preview.data
  const busy = claim.isPending || switchContext.isPending || sending || signingIn
  const needsPassword = session?.user.user_metadata?.needs_password === true
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
      {session && needsPassword ? (
        <form
          className="space-y-3"
          aria-label="Choose a password"
          onSubmit={(event) => {
            event.preventDefault()
            void savePassword()
          }}
        >
          <p className="text-sm text-gray-600 dark:text-dark-200">
            Signed in as <span className="font-medium">{email}</span>. Choose a password for next time. It is not emailed, and nobody else sets it.
          </p>
          <FormField
            label="Password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(event) => setPasswordValue(event.target.value)}
          />
          <Button type="submit" className="w-full" disabled={busy}>
            {signingIn ? 'Saving…' : 'Save password'}
          </Button>
        </form>
      ) : session ? (
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
          <p className="text-sm text-gray-600 dark:text-dark-200">
            No account is required yet. We email a one-time code to the invited address. You choose your own password after that.
          </p>
          <Button className="w-full" onClick={() => void requestCode()} disabled={busy}>
            {sending ? 'Sending…' : codeSent ? 'Email another code' : 'Email me a sign-in code'}
          </Button>
          {codeSent && (
            <form
              className="space-y-3"
              aria-label="Sign-in code"
              onSubmit={(event) => {
                event.preventDefault()
                void submitCode(code.trim())
              }}
            >
              <FormField
                label="Sign-in code"
                inputMode="numeric"
                autoComplete="one-time-code"
                value={code}
                onChange={(event) => setCode(event.target.value)}
              />
              <Button type="submit" className="w-full" disabled={busy || code.trim().length !== 6}>
                {signingIn ? 'Signing in…' : 'Sign in with code'}
              </Button>
            </form>
          )}
          <Button variant="secondary" className="w-full" onClick={() => navigate('/login', { state: { from: `/invite/${token}` } })}>
            I already have a password
          </Button>
        </div>
      )}
    </PublicLayout>
  )
}

function readCodeFromHash() {
  const match = /^#code=([0-9]{6})$/.exec(window.location.hash)
  return match?.[1] ?? ''
}
