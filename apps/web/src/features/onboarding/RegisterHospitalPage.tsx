import { useState } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Link } from 'react-router'
import { FormField } from '../../components/ui/FormField'
import { TimeZoneField } from '../../components/ui/TimeZoneField'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { useSubmitHospitalSignup } from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { defaultZone } from '../../lib/timeZones'
import { PublicLayout } from './PublicLayout'
import { hospitalSignupSchema, type HospitalSignupValues } from './onboardingSchemas'

const FIELDS = ['hospitalName', 'timeZone', 'contactName', 'contactEmail', 'phone', 'city'] as const

/**
 * Public "Register your hospital" (no sign-in). It only files a PENDING request: no hospital,
 * account or access exists until a platform operator approves it and the contact claims the
 * first-admin invite link.
 */
export function RegisterHospitalPage() {
  const submit = useSubmitHospitalSignup()
  const [done, setDone] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const {
    register,
    control,
    handleSubmit,
    setError: setFieldError,
    formState: { errors, isSubmitting },
  } = useForm<HospitalSignupValues>({
    resolver: zodResolver(hospitalSignupSchema),
    defaultValues: { hospitalName: '', timeZone: defaultZone(), contactName: '', contactEmail: '', phone: '', city: '', website: '' },
  })

  const onSubmit = async (values: HospitalSignupValues) => {
    setError(null)
    try {
      const result = await submit.mutateAsync(values)
      setDone(result?.message ?? 'Thank you. Your request was received.')
    } catch (e) {
      const fields = fieldErrors(e)
      for (const [field, text] of Object.entries(fields)) {
        if ((FIELDS as readonly string[]).includes(field)) setFieldError(field as (typeof FIELDS)[number], { message: text })
      }
      setError(
        Object.keys(fields).length
          ? 'Please fix the highlighted fields.'
          : problemCode(e) === 'email_registered'
            ? (e instanceof ApiError && e.problem?.detail) || 'This email is already registered. Please sign in or contact support.'
            : problemCode(e) === 'rate_limited' || (e instanceof ApiError && e.status === 429)
              ? 'Too many registrations were sent from here. Please try again later.'
              : 'Could not send your request. Check your connection and try again.',
      )
    }
  }

  if (done) {
    return (
      <PublicLayout title="Request received" subtitle="Register your hospital" illustration="tick">
        <Alert tone="info">{done}</Alert>
        <p className="text-sm text-gray-600 dark:text-dark-200">
          Nothing is set up yet. When your request is approved, the contact person receives a one-time link to create the hospital’s first admin
          account.
        </p>
        <Link to="/login" className="text-sm font-medium text-primary-600 underline dark:text-primary-400">
          Back to sign in
        </Link>
      </PublicLayout>
    )
  }

  return (
    <PublicLayout title="Register your hospital" subtitle="Request access to HMS. Our team reviews every request." illustration="lab" wide>
      {error && <Alert tone="error">{error}</Alert>}
      <form noValidate aria-label="Register your hospital" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-2">
        <div className="sm:col-span-2">
          <FormField label="Hospital name" autoComplete="organization" error={errors.hospitalName?.message} {...register('hospitalName')} />
        </div>
        <Controller
          control={control}
          name="timeZone"
          render={({ field }) => (
            <TimeZoneField
              label="Hospital time zone"
              hint="Appointment days and queues follow it. Search, e.g. Kolkata."
              error={errors.timeZone?.message}
              name={field.name}
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              ref={field.ref}
            />
          )}
        />
        <FormField label="City" autoComplete="address-level2" error={errors.city?.message} {...register('city')} />
        <FormField label="Your name" autoComplete="name" error={errors.contactName?.message} {...register('contactName')} />
        <FormField label="Work email" type="email" autoComplete="email" error={errors.contactEmail?.message} {...register('contactEmail')} />
        <FormField label="Phone" type="tel" autoComplete="tel" error={errors.phone?.message} {...register('phone')} />
        {/* honeypot: hidden from people and assistive tech; bots that fill it are dropped server-side */}
        <div aria-hidden="true" className="absolute -left-[9999px] h-0 w-0 overflow-hidden">
          <label>
            Website
            <input tabIndex={-1} autoComplete="off" {...register('website')} />
          </label>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 sm:col-span-2">
          <Link to="/login" className="text-sm font-medium text-primary-600 underline dark:text-primary-400">
            Already have an account? Sign in
          </Link>
          <Button type="submit" disabled={isSubmitting}>
            {isSubmitting ? 'Sending…' : 'Send request'}
          </Button>
        </div>
      </form>
      <p className="text-xs text-gray-600 dark:text-dark-200">Use synthetic details only in this demo. We store the request for review; it grants no access.</p>
    </PublicLayout>
  )
}
