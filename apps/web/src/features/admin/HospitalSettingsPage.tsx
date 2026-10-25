import { useEffect, useState } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { TimeZoneField } from '../../components/ui/TimeZoneField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { useBranches, useCurrentTenant, useUpdateCurrentTenant } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import type { UpdateTenantRequest } from '../../lib/api/types'
import { hospitalSchema, type HospitalValues } from './adminSchemas'

type Message = { tone: 'info' | 'error'; text: string }

/** Calling codes identity.country_code_for_zone already knows. */
const CALLING_CODES = ['+91', '+971', '+65', '+92', '+880', '+977', '+94', '+966', '+974', '+44', '+49', '+33', '+254', '+234', '+61', '+1']

export function HospitalSettingsPage({
  embedded = false,
  showCountryCode = false,
  submitLabel = 'Save settings',
  allowUnchanged = false,
  onSaved,
}: {
  embedded?: boolean
  showCountryCode?: boolean
  submitLabel?: string
  /** The wizard can confirm the prefilled hospital without editing it. */
  allowUnchanged?: boolean
  onSaved?: () => void
} = {}) {

/**
 * Hospital name and time zone (tenant_admin, PATCH /tenants/current). Branches without an override
 * follow this zone. A change that would move future bookings on the wall clock answers 409
 * time_zone_has_future_bookings: the admin confirms and the request is repeated with
 * confirmFutureBookings; while today's queue has entries the zone is locked (409 time_zone_locked).
 */
  const tenant = useCurrentTenant()
  const branches = useBranches()
  const save = useUpdateCurrentTenant()
  const [message, setMessage] = useState<Message | null>(null)
  const [confirm, setConfirm] = useState<{ body: UpdateTenantRequest; futureBookings: number } | null>(null)
  const {
    register,
    handleSubmit,
    reset,
    setError,
    control,
    formState: { errors, isSubmitting, isDirty },
  } = useForm<HospitalValues>({ resolver: zodResolver(hospitalSchema), defaultValues: { name: '', timeZone: '', defaultCountryCode: '' } })

  const current = tenant.data
  useEffect(() => {
    if (current) reset({ name: current.name, timeZone: current.timeZone ?? '', defaultCountryCode: current.defaultCountryCode ?? '' })
  }, [current, reset])

  const following = (branches.data ?? []).filter((b) => b.timezoneOverride === null)
  const overriding = (branches.data ?? []).filter((b) => typeof b.timezoneOverride === 'string')

  const send = async (body: UpdateTenantRequest) => {
    setMessage(null)
    try {
      const saved = await save.mutateAsync(body)
      setConfirm(null)
      reset({ name: saved.name, timeZone: saved.timeZone ?? '', defaultCountryCode: saved.defaultCountryCode ?? '' })
      setMessage({
        tone: 'info',
        text: body.timeZone ? `Saved. The hospital time zone is now ${saved.timeZone ?? body.timeZone}.` : 'Saved.',
      })
      onSaved?.()
    } catch (error) {
      const problem = error instanceof ApiError ? error.problem : null
      if (error instanceof ApiError && error.status === 409 && problem?.code === 'time_zone_has_future_bookings') {
        setConfirm({ body, futureBookings: problem.futureBookings ?? 0 })
        return
      }
      setConfirm(null)
      for (const [field, msg] of Object.entries(fieldErrors(error))) {
        if (field === 'name' || field === 'timeZone') setError(field, { message: msg })
      }
      setMessage({
        tone: 'error',
        text:
          problem?.code === 'time_zone_locked'
            ? "Today's queue already has patients in a branch that follows the hospital zone. Change the time zone after the day closes."
            : error instanceof ApiError && error.status === 403
              ? 'Only tenant admins can change hospital settings.'
              : 'Could not save the hospital settings.',
      })
    }
  }

  const onSubmit = (values: HospitalValues) => {
    if (!current) return
    const body: UpdateTenantRequest = {}
    if (values.name !== current.name) body.name = values.name
    if (values.timeZone !== (current.timeZone ?? '')) body.timeZone = values.timeZone
    if (showCountryCode && values.defaultCountryCode && values.defaultCountryCode !== (current.defaultCountryCode ?? '')) {
      body.defaultCountryCode = values.defaultCountryCode
    }
    if (!body.name && !body.timeZone && !body.defaultCountryCode) {
      if (allowUnchanged) {
        onSaved?.()
        return
      }
      setMessage({ tone: 'info', text: 'Nothing to save.' })
      return
    }
    return send(body)
  }

  return (
    <div className="space-y-6">
      {!embedded && <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Hospital settings</h1>}
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      {tenant.isError && <Alert tone="error">Could not load the hospital settings.</Alert>}
      {tenant.isPending && <p role="status">Loading…</p>}
      {current && (
        <div className={embedded ? undefined : 'grid gap-6 lg:grid-cols-3'}>
          <Card title="Hospital" className={embedded ? undefined : 'lg:col-span-2'}>
            <form noValidate aria-label="Hospital settings" onSubmit={handleSubmit(onSubmit)} className="space-y-4">
              <FormField label="Hospital name" error={errors.name?.message} {...register('name')} />
              <Controller
                control={control}
                name="timeZone"
                render={({ field }) => (
                  <TimeZoneField
                    label="Hospital time zone"
                    hint="Days, slots and queue dates of branches without their own zone follow it."
                    error={errors.timeZone?.message}
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}
                    onBlur={field.onBlur}
                    ref={field.ref}
                  />
                )}
              />
              {showCountryCode && (
                <SelectField
                  label="Default country code"
                  hint="Applied to phone numbers typed without a country code."
                  error={errors.defaultCountryCode?.message}
                  {...register('defaultCountryCode')}
                >
                  {(current.defaultCountryCode && !CALLING_CODES.includes(current.defaultCountryCode)
                    ? [current.defaultCountryCode, ...CALLING_CODES]
                    : CALLING_CODES
                  ).map((code) => (
                    <option key={code} value={code}>
                      {code}
                    </option>
                  ))}
                </SelectField>
              )}
              <p className="text-sm text-gray-600 dark:text-dark-200">
                Changing the zone keeps booked appointments at the same instant, so their local times move. You will be asked to confirm if
                future bookings are affected.
              </p>
              <Button type="submit" disabled={isSubmitting || save.isPending || (!allowUnchanged && !isDirty)}>
                {submitLabel}
              </Button>
            </form>
          </Card>
          {!embedded && <Card title="Branches">
            {branches.isError && <Alert tone="error">Could not load branches.</Alert>}
            <dl className="space-y-3 text-sm" data-testid="hospital-zone-branches">
              <div>
                <dt className="font-medium text-gray-800 dark:text-dark-100">Follow the hospital zone</dt>
                <dd className="text-gray-600 dark:text-dark-200">{following.length ? following.map((b) => b.name).join(', ') : 'None'}</dd>
              </div>
              <div>
                <dt className="font-medium text-gray-800 dark:text-dark-100">Own time zone</dt>
                <dd className="text-gray-600 dark:text-dark-200">
                  {overriding.length ? overriding.map((b) => `${b.name} (${b.timezoneOverride})`).join(', ') : 'None'}
                </dd>
              </div>
            </dl>
          </Card>}
        </div>
      )}
      <ConfirmDialog
        open={!!confirm}
        title="Move future bookings?"
        confirmLabel="Change time zone"
        busy={save.isPending}
        onCancel={() => setConfirm(null)}
        onConfirm={() => confirm && void send({ ...confirm.body, confirmFutureBookings: true })}
      >
        {confirm && (
          <p>
            {confirm.futureBookings} future booking{confirm.futureBookings === 1 ? '' : 's'} in branches that follow the hospital zone will keep their
            instant, so their local times move to {confirm.body.timeZone}. Change it anyway?
          </p>
        )}
      </ConfirmDialog>
    </div>
  )
}
