import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Navigate, useLocation, useNavigate } from 'react-router'
import { loginSchema, type LoginFormValues } from './loginSchema'
import { useAuth } from './AuthProvider'
import { FormField } from '../../components/ui/FormField'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'

export function LoginPage() {
  const { session, signIn, configured, signedOutReason } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const [authError, setAuthError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginFormValues>({ resolver: zodResolver(loginSchema), defaultValues: { email: '', password: '' } })

  const from = (location.state as { from?: string } | null)?.from ?? '/'
  if (session) return <Navigate to={from} replace />

  const onSubmit = async (values: LoginFormValues) => {
    setAuthError(null)
    const { error } = await signIn(values.email, values.password)
    if (error) {
      setAuthError(error)
      return
    }
    navigate(from, { replace: true })
  }

  return (
    <main id="main-content" className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6 rounded-lg border border-slate-200 bg-white p-8 shadow-sm">
        <div>
          <h1 className="text-2xl font-semibold">Sign in to HMS</h1>
          <p className="mt-1 text-sm text-slate-600">Hospital Management System</p>
        </div>
        {!configured && (
          <Alert tone="warning">
            Authentication is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY (see .env.example).
          </Alert>
        )}
        {signedOutReason === 'idle' && (
          <Alert tone="info">You were signed out after a period of inactivity. Sign in again to continue.</Alert>
        )}
        {signedOutReason === 'ended' && (
          <Alert tone="info">Your session ended (signed out in another tab, or it expired). Sign in again to continue.</Alert>
        )}
        {authError && <Alert tone="error">{authError}</Alert>}
        <form noValidate onSubmit={handleSubmit(onSubmit)} className="space-y-4" aria-label="Sign in">
          <FormField label="Email" type="email" autoComplete="username" error={errors.email?.message} {...register('email')} />
          <FormField
            label="Password"
            type="password"
            autoComplete="current-password"
            error={errors.password?.message}
            {...register('password')}
          />
          <Button type="submit" className="w-full" disabled={isSubmitting || !configured}>
            {isSubmitting ? 'Signing in…' : 'Sign in'}
          </Button>
        </form>
        <p className="text-xs text-slate-500">Synthetic demo data only. Not for clinical use.</p>
      </div>
    </main>
  )
}
