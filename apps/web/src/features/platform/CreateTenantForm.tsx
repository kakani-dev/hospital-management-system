import { useEffect, useState } from 'react'
import { Controller, useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { FormField } from '../../components/ui/FormField'
import { TimeZoneField } from '../../components/ui/TimeZoneField'
import { Button } from '../../components/ui/Button'
import { Alert } from '../../components/ui/Alert'
import { usePlatformCreateTenant } from '../../lib/api/hooks'
import { fieldErrors, problemCode } from '../../lib/api/client'
import { codeFromName, defaultZone } from '../../lib/timeZones'
import type { HospitalApproved } from '../../lib/api/types'
import { createTenantSchema, type CreateTenantValues } from '../onboarding/onboardingSchemas'

const FIELDS = ['name', 'code', 'timeZone', 'adminEmail'] as const

/** Operator creates a hospital directly: identity.create_tenant (required zone) + first-admin invite link. */
export function CreateTenantForm({ onCreated, onCancel }: { onCreated: (result: HospitalApproved, values: CreateTenantValues) => void; onCancel: () => void }) {
  const create = usePlatformCreateTenant()
  const [error, setError] = useState<string | null>(null)
  const [codeTouched, setCodeTouched] = useState(false)
  const {
    register,
    handleSubmit,
    setValue,
    setError: setFieldError,
    control,
    formState: { errors, isSubmitting },
  } = useForm<CreateTenantValues>({ resolver: zodResolver(createTenantSchema), defaultValues: { name: '', code: '', timeZone: defaultZone(), adminEmail: '' } })
  const name = useWatch({ control, name: 'name' })
  useEffect(() => {
    if (!codeTouched && name) setValue('code', codeFromName(name))
  }, [name, codeTouched, setValue])

  const onSubmit = async (values: CreateTenantValues) => {
    setError(null)
    try {
      onCreated(await create.mutateAsync(values), values)
    } catch (e) {
      const fields = fieldErrors(e)
      for (const [field, text] of Object.entries(fields)) {
        if ((FIELDS as readonly string[]).includes(field)) setFieldError(field as (typeof FIELDS)[number], { message: text })
      }
      setError(
        Object.keys(fields).length
          ? 'Please fix the highlighted fields.'
          : problemCode(e) === 'conflict'
            ? 'A hospital with this code already exists. Choose another code.'
            : 'Could not create the hospital. Try again.',
      )
    }
  }

  return (
    <form noValidate aria-label="Create hospital" onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      {error && <Alert tone="error">{error}</Alert>}
      <FormField label="Hospital name" error={errors.name?.message} {...register('name')} />
      <FormField
        label="Hospital code"
        hint="Unique, lowercase; used in URLs and support. Cannot be changed later."
        error={errors.code?.message}
        {...register('code', { onChange: () => setCodeTouched(true) })}
      />
      <Controller
        control={control}
        name="timeZone"
        render={({ field }) => (
          <TimeZoneField
            label="Hospital time zone"
            hint="Pick from the list or search, e.g. Kolkata."
            error={errors.timeZone?.message}
            name={field.name}
            value={field.value}
            onChange={field.onChange}
            onBlur={field.onBlur}
            ref={field.ref}
          />
        )}
      />
      <FormField
        label="First admin email"
        type="email"
        hint="We email them a one-time invite link to become the hospital’s tenant admin."
        error={errors.adminEmail?.message}
        {...register('adminEmail')}
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="secondary" onClick={onCancel}>
          Cancel
        </Button>
        <Button type="submit" disabled={isSubmitting}>
          {isSubmitting ? 'Creating…' : 'Create hospital'}
        </Button>
      </div>
    </form>
  )
}
