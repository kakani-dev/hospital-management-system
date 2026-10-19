import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Link, Navigate, useLocation, useNavigate } from 'react-router'
import { loginSchema, type LoginFormValues } from './loginSchema'
import { useAuth } from './AuthProvider'
import { EnvelopeIcon, LockClosedIcon } from '@heroicons/react/24/outline'
import { Card } from '@tailux/components/ui'
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
    <main id="main-content" className="min-h-100vh grid w-full grow grid-cols-1 place-items-center">
      <div className="w-full max-w-[26rem] p-4 sm:px-5">
        <div className="text-center">
          <span
            aria-hidden="true"
            className="mx-auto flex size-16 items-center justify-center rounded-2xl bg-primary-600 text-4xl font-bold text-white dark:bg-primary-500"
          >
            +
          </span>
          <div className="mt-4">
            <h1 className="text-2xl font-semibold text-gray-600 dark:text-dark-100">Sign in to HMS</h1>
            <p className="text-gray-500 dark:text-dark-300">Hospital Management System</p>
          </div>
        </div>
        <Card className="mt-5 space-y-4 rounded-lg p-5 lg:p-7">
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
            <FormField
              label="Email"
              type="email"
              autoComplete="username"
              placeholder="Enter email"
              prefix={<EnvelopeIcon className="size-5 transition-colors duration-200" strokeWidth="1" aria-hidden="true" />}
              error={errors.email?.message}
              {...register('email')}
            />
            <FormField
              label="Password"
              type="password"
              autoComplete="current-password"
              placeholder="Enter password"
              prefix={<LockClosedIcon className="size-5 transition-colors duration-200" strokeWidth="1" aria-hidden="true" />}
              error={errors.password?.message}
              {...register('password')}
            />
            <Button type="submit" className="mt-1 w-full" disabled={isSubmitting || !configured}>
              {isSubmitting ? 'Signing in…' : 'Sign in'}
            </Button>
          </form>
        </Card>
        <p className="mt-4 text-center text-sm text-gray-600 dark:text-dark-200">
          New hospital?{' '}
          <Link to="/register-hospital" className="font-medium text-primary-600 underline dark:text-primary-400">
            Register your hospital
          </Link>
        </p>
        <p className="mt-8 text-center text-xs text-gray-500 dark:text-dark-300">Synthetic demo data only. Not for clinical use.</p>
      </div>
    </main>
  )
}
