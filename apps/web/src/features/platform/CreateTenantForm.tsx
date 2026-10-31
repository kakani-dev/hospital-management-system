import { useEffect, useState } from 'react'
import { Controller, useFieldArray, useForm, useWatch } from 'react-hook-form'
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
import { branchPayload } from './branchPayload'

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
  } = useForm<CreateTenantValues>({ resolver: zodResolver(createTenantSchema), defaultValues: { name: '', code: '', timeZone: defaultZone(), adminEmail: '', branches: [{ name: 'Main', address: '' }] } })
  const branchRows = useFieldArray({ control, name: 'branches' })
  const name = useWatch({ control, name: 'name' })
  useEffect(() => {
    if (!codeTouched && name) setValue('code', codeFromName(name))
  }, [name, codeTouched, setValue])

  const onSubmit = async (values: CreateTenantValues) => {
    setError(null)
    try {
      onCreated(await create.mutateAsync({ name: values.name, code: values.code, timeZone: values.timeZone, adminEmail: values.adminEmail, branches: branchPayload(values.branches) }), values)
    } catch (e) {
      const fields = fieldErrors(e)
      for (const [field, text] of Object.entries(fields)) {
        if (field === 'branches') setFieldError('branches', { message: text })
        else if ((FIELDS as readonly string[]).includes(field)) setFieldError(field as (typeof FIELDS)[number], { message: text })
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
      <fieldset className="space-y-2" data-testid="onboard-branches">
        <legend className="text-sm font-medium text-gray-800 dark:text-dark-100">Branches</legend>
        <p className="text-xs text-gray-600 dark:text-dark-200">The first branch is the main branch. Default settings (billing approvals, refunds, reminders, registration, pharmacy) are applied from platform config.</p>
        {branchRows.fields.map((f, i) => (
          <div key={f.id} className="flex items-start gap-2" data-testid={`onboard-branch-${i}`}>
            <div className="flex-1">
              <FormField label={`Branch ${i + 1} name`} error={errors.branches?.[i]?.name?.message} {...register(`branches.${i}.name` as const)} />
            </div>
            <div className="flex-1">
              <FormField label={`Branch ${i + 1} address`} hint={i === 0 ? 'Optional' : undefined} {...register(`branches.${i}.address` as const)} />
            </div>
            {branchRows.fields.length > 1 && (
              <button type="button" className="mt-6 rounded px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:text-red-400 dark:hover:bg-dark-600" aria-label={`Remove branch ${i + 1}`} data-testid={`onboard-branch-remove-${i}`} onClick={() => branchRows.remove(i)}>
                Remove
              </button>
            )}
          </div>
        ))}
        {(errors.branches?.message || errors.branches?.root?.message) && (
          <p className="text-xs text-red-700 dark:text-red-400" role="alert">{errors.branches?.message ?? errors.branches?.root?.message}</p>
        )}
        {branchRows.fields.length < 20 && (
          <button type="button" className="rounded px-2 py-1 text-xs font-medium text-primary-700 hover:bg-primary-50 dark:text-primary-300 dark:hover:bg-dark-600" data-testid="onboard-branch-add" onClick={() => branchRows.append({ name: '', address: '' })}>
            + Add branch
          </button>
        )}
      </fieldset>
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
