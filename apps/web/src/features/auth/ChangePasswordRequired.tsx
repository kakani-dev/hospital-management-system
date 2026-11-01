import { useState } from 'react'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { FormField } from '../../components/ui/FormField'
import { PublicLayout } from '../onboarding/PublicLayout'
import { isStrongEnough, PASSWORD_POLICY_TEXT } from '../../lib/passwordPolicy'
import { useAuth } from './AuthProvider'

/**
 * Shown instead of the app while the account still has a password an admin set (#311,
 * needs_password). The person picks their own before anything else; they can also sign out.
 */
export function ChangePasswordRequired() {
  const { email, setPassword, signOut } = useAuth()
  const [password, setPasswordValue] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const save = async () => {
    setError(null)
    if (!isStrongEnough(password)) return setError(PASSWORD_POLICY_TEXT)
    if (password !== confirm) return setError('The two passwords do not match.')
    setBusy(true)
    try {
      const result = await setPassword(password)
      if (result.error) setError(result.error)
      else {
        setPasswordValue('')
        setConfirm('')
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <PublicLayout title="Choose your own password" illustration="file">
      {error && <Alert tone="error">{error}</Alert>}
      <form
        className="space-y-3"
        aria-label="Choose your own password"
        data-testid="change-password-required"
        onSubmit={(event) => {
          event.preventDefault()
          void save()
        }}
      >
        <p className="text-sm text-gray-600 dark:text-dark-200">
          Signed in as <span className="font-medium">{email}</span>. Your hospital admin set a temporary password. Choose your own to continue.
        </p>
        <FormField
          label="New password"
          data-testid="change-password-new"
          type="password"
          autoComplete="new-password"
          value={password}
          onChange={(event) => setPasswordValue(event.target.value)}
        />
        <FormField
          label="Confirm new password"
          data-testid="change-password-confirm"
          type="password"
          autoComplete="new-password"
          value={confirm}
          onChange={(event) => setConfirm(event.target.value)}
        />
        <p className="text-xs text-gray-500 dark:text-dark-300">{PASSWORD_POLICY_TEXT}</p>
        <Button type="submit" className="w-full" disabled={busy} data-testid="change-password-save">
          {busy ? 'Saving…' : 'Save and continue'}
        </Button>
        <Button type="button" variant="ghost" className="w-full" onClick={() => void signOut()} data-testid="change-password-sign-out">
          Sign out
        </Button>
      </form>
    </PublicLayout>
  )
}
