import { useEffect, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { Link, useLocation, useNavigate } from 'react-router'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { transientWriteMessage } from '../../lib/api/errors'
import type { RegisterPatientState, ReturnedPatientState } from './registerReturn'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { useCreatePatient } from '../../lib/api/hooks'
import { ApiError, apiClient, fieldErrors } from '../../lib/api/client'
import { SEXES, type DuplicateCandidate } from '../../lib/api/types'
import { DuplicateWarning } from './DuplicateWarning'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { createPatientSchema, toCreatePatientRequest, type PatientFormValues } from './patientSchema'
import { useBranchToday, useBranchZonedResolver } from './useBranchZonedResolver'

export function RegisterPatientPage() {
  const navigate = useNavigate()
  const location = useLocation()
  // Opened from a patient picker's "No match: register new patient": pre-fill and go back after.
  const [origin] = useState(() => (location.state as RegisterPatientState | null) ?? {})
  const { branches, activeBranchId, activeTenant } = useCurrentContext()
  const createPatient = useCreatePatient()
  const resolver = useBranchZonedResolver<PatientFormValues>(createPatientSchema)
  const [formError, setFormError] = useState<string | null>(null)
  const [duplicates, setDuplicates] = useState<{ matches: DuplicateCandidate[]; values: PatientFormValues } | null>(null)
  const [creatingAnyway, setCreatingAnyway] = useState(false)
  const [retryValues, setRetryValues] = useState<PatientFormValues | null>(null)
  const {
    register,
    handleSubmit,
    setError,
    setValue,
    getValues,
    setFocus,
    control,
    formState: { errors, isSubmitting },
  } = useForm<PatientFormValues>({
    resolver,
    defaultValues: {
      mrn: origin.prefill?.mrn ?? '',
      firstName: origin.prefill?.firstName ?? '',
      lastName: origin.prefill?.lastName ?? '',
      dateOfBirth: '',
      sex: 'unknown',
      registeredBranchId: '',
      phone: '',
      email: '',
    },
  })

  // Keyboard flow: start typing straight away, in the first field the search did not fill.
  useEffect(() => {
    const p = origin.prefill ?? {}
    setFocus(!p.mrn ? 'mrn' : !p.firstName ? 'firstName' : !p.lastName ? 'lastName' : 'dateOfBirth')
  }, [origin, setFocus])

  // DOB "today" is the selected branch's date — the API validates in the branch's zone.
  const branchToday = useBranchToday(useWatch({ control, name: 'registeredBranchId' }))

  // Default the branch to the active one once /me has loaded.
  useEffect(() => {
    if (!getValues('registeredBranchId')) {
      const initial = activeBranchId ?? branches[0]?.id
      if (initial) setValue('registeredBranchId', initial)
    }
  }, [activeBranchId, branches, getValues, setValue])

  const create = async (values: PatientFormValues) => {
    setFormError(null)
    setRetryValues(null)
    try {
      const created = await createPatient.mutateAsync(toCreatePatientRequest(values))
      if (origin.returnTo) {
        const back: ReturnedPatientState = { ...origin.returnState, pickedPatient: created }
        navigate(origin.returnTo, { replace: true, state: back })
      } else {
        navigate('/patients', { replace: true, state: { registered: created.mrn } })
      }
    } catch (error) {
      setDuplicates(null)
      // Cold server / timeout: never auto-retried; offer Retry (a duplicate MRN is still caught by 409).
      const transient = transientWriteMessage(error, 'register the patient')
      if (transient) {
        setFormError(transient)
        setRetryValues(values)
        return
      }
      if (error instanceof ApiError && error.status === 409) {
        setError('mrn', { message: 'This MRN already exists in this hospital' })
        return
      }
      const fields = fieldErrors(error)
      for (const [field, message] of Object.entries(fields)) {
        if (field in values) setError(field as keyof PatientFormValues, { message })
      }
      setFormError(
        error instanceof ApiError && error.status === 403
          ? 'You are not allowed to register patients at this branch.'
          : Object.keys(fields).length
            ? 'Please fix the highlighted fields.'
            : 'Could not register the patient. Try again.',
      )
    }
  }

  // Possible-match check at submit (same tenant: name + DOB, or phone). Advisory only: if the
  // check itself fails, registration goes ahead and the API's own constraints still apply.
  const onSubmit = async (values: PatientFormValues) => {
    setFormError(null)
    setDuplicates(null)
    const request = toCreatePatientRequest(values)
    let matches: DuplicateCandidate[] = []
    try {
      matches = await apiClient.patients.duplicates({
        firstName: request.firstName,
        lastName: request.lastName,
        dateOfBirth: request.dateOfBirth,
        phone: request.phone,
      })
    } catch {
      matches = []
    }
    if (matches.length > 0) {
      setDuplicates({ matches, values })
      return
    }
    await create(values)
  }

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Register patient</h1>
        <Link to={origin.returnTo ?? '/patients'} className="text-sm text-brand-800 underline">
          {origin.returnTo ? 'Back' : 'Back to patients'}
        </Link>
      </div>
      <Card>
        <p className="mb-4 text-sm text-slate-600">
          Registering in <strong>{activeTenant?.name ?? '—'}</strong>. MRNs must be unique within this hospital.
        </p>
        {formError && (
          <div className="mb-4">
            {retryValues ? (
              <RetryAlert message={formError} busy={createPatient.isPending} onRetry={() => void create(retryValues)} />
            ) : (
              <Alert tone="error">{formError}</Alert>
            )}
          </div>
        )}
        {duplicates && (
          <div className="mb-4">
            <DuplicateWarning
              matches={duplicates.matches}
              busy={creatingAnyway}
              onProceed={async () => {
                setCreatingAnyway(true)
                try {
                  await create(duplicates.values)
                } finally {
                  setCreatingAnyway(false)
                }
              }}
              onDismiss={() => setDuplicates(null)}
            />
          </div>
        )}
        <form noValidate aria-label="Register patient" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-2">
          <FormField label="MRN" autoComplete="off" error={errors.mrn?.message} {...register('mrn')} />
          <SelectField label="Registered branch" error={errors.registeredBranchId?.message} {...register('registeredBranchId')}>
            <option value="">Select a branch…</option>
            {branches.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </SelectField>
          <FormField label="First name" autoComplete="off" error={errors.firstName?.message} {...register('firstName')} />
          <FormField label="Last name" autoComplete="off" error={errors.lastName?.message} {...register('lastName')} />
          <FormField
            label="Date of birth"
            type="date"
            min="1900-01-01"
            max={branchToday}
            error={errors.dateOfBirth?.message}
            {...register('dateOfBirth')}
          />
          <SelectField label="Sex" error={errors.sex?.message} {...register('sex')}>
            {SEXES.map((s) => (
              <option key={s} value={s}>
                {s[0]!.toUpperCase() + s.slice(1)}
              </option>
            ))}
          </SelectField>
          <FormField label="Phone (optional)" type="tel" autoComplete="off" error={errors.phone?.message} {...register('phone')} />
          <FormField label="Email (optional)" type="email" autoComplete="off" error={errors.email?.message} {...register('email')} />
          <div className="sm:col-span-2">
            <Button type="submit" disabled={isSubmitting || creatingAnyway}>
              {isSubmitting ? 'Registering…' : 'Register patient'}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
