import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { FormField } from '../../components/ui/FormField'
import { useAuth } from '../auth/AuthProvider'
import { apiClient, ApiError } from '../../lib/api/client'
import { PublicLayout } from '../onboarding/PublicLayout'

const MIN_PASSWORD = 8

/**
 * /reset-password/:token. A hospital admin emailed this one-time link (#309). The link is only used
 * when the person presses Continue (mail scanners that open links do not burn it). The server swaps
 * it for a one-time sign-in, then the person chooses a new password; it is never emailed or shown to the admin.
 */
export function ResetPasswordPage() {
  const { token = '' } = useParams()
  const { session, email, signInWithTokenHash, setPassword } = useAuth()
  const navigate = useNavigate()
  const [error, setError] = useState<string | null>(null)
  const [linkUsed, setLinkUsed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [password, setPasswordValue] = useState('')
  const needsPassword = linkUsed && session?.user.user_metadata?.needs_password === true

  const openLink = async () => {
    setError(null)
    setBusy(true)
    try {
      const proof = await apiClient.publicApi.exchangePasswordReset(token)
      const result = await signInWithTokenHash(proof.tokenHash)
      if (result.error) setError(result.error)
      else setLinkUsed(true)
    } catch (e) {
      setError(
        e instanceof ApiError && e.status === 404
          ? 'This reset link was already used or has expired. Ask your hospital admin for a new one.'
          : 'Could not open the reset link. Try again in a moment.',
      )
    } finally {
      setBusy(false)
    }
  }

  const savePassword = async () => {
    setError(null)
    if (password.length < MIN_PASSWORD) {
      setError(`Password must be at least ${MIN_PASSWORD} characters.`)
      return
    }
    setBusy(true)
    try {
      const result = await setPassword(password)
      setPasswordValue('')
      if (result.error) setError(result.error)
      else navigate('/', { replace: true })
    } finally {
      setBusy(false)
    }
  }

  return (
    <PublicLayout title="Reset your password" illustration="file">
      {error && <Alert tone="error">{error}</Alert>}
      {needsPassword ? (
        <form
          className="space-y-3"
          aria-label="Choose a new password"
          data-testid="reset-password-form"
          onSubmit={(event) => {
            event.preventDefault()
            void savePassword()
          }}
        >
          <p className="text-sm text-gray-600 dark:text-dark-200">
            Signed in as <span className="font-medium">{email}</span>. Choose a new password. It is not emailed, and your admin never sees it.
          </p>
          <FormField
            label="New password"
            data-testid="auth-reset-password-new"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(event) => setPasswordValue(event.target.value)}
          />
          <Button type="submit" className="w-full" disabled={busy} data-testid="reset-password-save">
            {busy ? 'Saving…' : 'Save new password'}
          </Button>
        </form>
      ) : (
        <div className="space-y-3">
          <p className="text-sm text-gray-600 dark:text-dark-200">
            Your hospital admin sent you this link. It works once and expires 1 hour after it was sent.
          </p>
          <Button className="w-full" onClick={() => void openLink()} disabled={busy} data-testid="reset-password-continue">
            {busy ? 'Checking…' : 'Continue'}
          </Button>
          <Link to="/login" className="block text-center text-sm font-medium text-primary-600 underline dark:text-primary-400">
            Go to sign in
          </Link>
        </div>
      )}
    </PublicLayout>
  )
}
