import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Navigate, useNavigate } from 'react-router'
import { loginSchema, type LoginFormValues } from './loginSchema'
import { useSession } from './session'
import { FormField } from '../../components/ui/FormField'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'

export function LoginPage() {
  const { session, signInDemo } = useSession()
  const navigate = useNavigate()
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginFormValues>({ resolver: zodResolver(loginSchema), defaultValues: { email: '', password: '' } })

  if (session) return <Navigate to="/" replace />

  const onSubmit = (values: LoginFormValues) => {
    signInDemo(values.email)
    navigate('/', { replace: true })
  }

  return (
    <main id="main-content" className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6 rounded-lg border border-slate-200 bg-white p-8 shadow-sm">
        <div>
          <h1 className="text-2xl font-semibold">Sign in to HMS</h1>
          <p className="mt-1 text-sm text-slate-600">Hospital Management System</p>
        </div>
        <Alert tone="warning">
          Sprint 0 placeholder: credentials are validated for format only and a synthetic demo session is created. Real
          authentication (Supabase Auth) arrives in Sprint 1.
        </Alert>
        <form noValidate onSubmit={handleSubmit(onSubmit)} className="space-y-4" aria-label="Sign in">
          <FormField label="Email" type="email" autoComplete="username" error={errors.email?.message} {...register('email')} />
          <FormField
            label="Password"
            type="password"
            autoComplete="current-password"
            error={errors.password?.message}
            {...register('password')}
          />
          <Button type="submit" className="w-full" disabled={isSubmitting}>
            Sign in
          </Button>
        </form>
      </div>
    </main>
  )
}
