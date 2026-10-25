import { useEffect, useState, type KeyboardEvent, type ReactNode } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { ageOn } from './patientLabel'
import { Link, useLocation, useNavigate } from 'react-router'
import { toast } from 'sonner'
import { RetryAlert } from '../../components/ui/RetryAlert'
import { transientWriteMessage } from '../../lib/api/errors'
import type { RegisterPatientState, ReturnedPatientState } from './registerReturn'
import { Illustration } from '../../components/ui/Illustration'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { PATIENT_SEARCH_DEBOUNCE_MS, useCreatePatient, useTenantCountryCode } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { ApiError, apiClient, fieldErrors } from '../../lib/api/client'
import { SEXES, type DuplicateCandidate, type PatientSummary } from '../../lib/api/types'
import { DuplicateWarning } from './DuplicateWarning'
import { duplicateMode } from './duplicateCheck'
import { defaultBranchId, useCurrentContext } from '../tenancy/useCurrentContext'
import { createPatientSchema, toCreatePatientRequest, type PatientFormValues } from './patientSchema'
import { useBranchToday, useBranchZonedResolver } from './useBranchZonedResolver'
import { WhatsappFields } from './WhatsappFields'

/**
 * Embedded (compact) mode, used inline by the booking drawer's "+ New patient": the same form,
 * validation, duplicate check and server-generated MRN. Sex stays "unknown" and the branch is the
 * booking branch. Date of birth and ABHA are included so the live duplicate check can match
 * name+DOB+phone and ABHA. Not a <form> of its own (it sits inside the booking form): Enter saves via onKeyDown.
 */
export interface EmbeddedRegisterOptions {
  prefill?: RegisterPatientState['prefill']
  branchId: string
  /** "select" = Save patient; "book" = Save & book (shown only when canBook). */
  onCreated: (patient: PatientSummary, action: 'select' | 'book') => void
  onUseExisting: (match: DuplicateCandidate) => void
  onCancel: () => void
  canBook?: boolean
}

export function RegisterPatientPage({
  embedded,
  consent,
  afterSave,
}: {
  embedded?: EmbeddedRegisterOptions
  /** Rendered above the save action. Omitted leaves registration unchanged. */
  consent?: ReactNode
  /** Runs after the patient exists and before navigation. Omitted leaves registration unchanged. */
  afterSave?: (patient: PatientSummary) => void | Promise<void>
} = {}) {
  const navigate = useNavigate()
  const location = useLocation()
  // Opened from a patient picker's "No match: register new patient": pre-fill and go back after.
  const [origin] = useState<RegisterPatientState>(() => (embedded ? { prefill: embedded.prefill } : ((location.state as RegisterPatientState | null) ?? {})))
  const [action, setAction] = useState<'select' | 'book'>('select')
  const isEmbedded = !!embedded
  const countryCode = useTenantCountryCode()
  const { branches, activeTenant, me } = useCurrentContext()
  const createPatient = useCreatePatient()
  const resolver = useBranchZonedResolver<PatientFormValues>(createPatientSchema)
  const [formError, setFormError] = useState<string | null>(null)
  const [duplicates, setDuplicates] = useState<{ matches: DuplicateCandidate[]; values: PatientFormValues } | null>(null)
  const [duplicateReason, setDuplicateReason] = useState('')
  const [liveFetched, setLiveFetched] = useState<{ key: string; matches: DuplicateCandidate[] } | null>(null)
  const [dismissedLive, setDismissedLive] = useState<string | null>(null)
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
      firstName: origin.prefill?.firstName ?? '',
      lastName: origin.prefill?.lastName ?? '',
      dateOfBirth: '',
      sex: 'unknown',
      registeredBranchId: embedded?.branchId ?? '',
      phone: origin.prefill?.phone ?? '',
      email: '',
      whatsappSameAsPhone: true,
      whatsappNumber: '',
      abhaNumber: '',
    },
  })

  // Keyboard flow: start typing straight away, in the first field the search did not fill.
  useEffect(() => {
    const p = origin.prefill ?? {}
    setFocus(!p.firstName ? 'firstName' : !p.lastName ? 'lastName' : isEmbedded ? 'phone' : 'dateOfBirth')
  }, [origin, setFocus, isEmbedded])

  const watchedName = useWatch({ control, name: 'firstName' }) ?? ''
  const watchedLast = useWatch({ control, name: 'lastName' }) ?? ''
  const watchedPhone = useWatch({ control, name: 'phone' }) ?? ''
  const watchedDob = useWatch({ control, name: 'dateOfBirth' }) ?? ''
  const watchedAbha = useWatch({ control, name: 'abhaNumber' }) ?? ''
  const liveKey = [watchedName, watchedLast, watchedPhone, watchedDob, watchedAbha].join('\u0001')
  const debouncedLive = useDebouncedValue(liveKey, PATIENT_SEARCH_DEBOUNCE_MS)
  // Booking drawer only: warn while the name or phone is still being typed. The full page keeps
  // the check at submit so a half-typed form never interrupts registration.
  useEffect(() => {
    if (!isEmbedded || dismissedLive === debouncedLive) return
    const [firstName = '', lastName = '', phone = '', dateOfBirth = '', abhaNumber = ''] = debouncedLive.split('\u0001')
    const nameReady = firstName.trim().length >= 2 && lastName.trim().length >= 2
    const phoneReady = phone.replace(/\D/g, '').length >= 7
    const abhaReady = abhaNumber.replace(/\D/g, '').length === 14
    if (!nameReady && !phoneReady && !abhaReady) return
    let cancelled = false
    const key = debouncedLive
    void apiClient.patients
      .duplicates({
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        ...(dateOfBirth.trim() ? { dateOfBirth: dateOfBirth.trim() } : {}),
        ...(phone.trim() ? { phone: phone.trim() } : {}),
        ...(abhaReady ? { abhaNumber: abhaNumber.trim() } : {}),
      })
      .then((matches) => {
        if (!cancelled) setLiveFetched({ key, matches })
      })
      .catch(() => {
        if (!cancelled) setLiveFetched({ key, matches: [] })
      })
    return () => {
      cancelled = true
    }
  }, [debouncedLive, dismissedLive, isEmbedded])
  const [liveFirst = '', liveLast = '', livePhone = '', , liveAbha = ''] = debouncedLive.split('\u0001')
  const liveReady =
    isEmbedded &&
    dismissedLive !== debouncedLive &&
    ((liveFirst.trim().length >= 2 && liveLast.trim().length >= 2) ||
      livePhone.replace(/\D/g, '').length >= 7 ||
      liveAbha.replace(/\D/g, '').length === 14)
  const liveMatches = liveReady && liveFetched?.key === debouncedLive && liveFetched.matches.length > 0 ? liveFetched.matches : null

  // DOB "today" is the selected branch's date — the API validates in the branch's zone.
  const branchToday = useBranchToday(useWatch({ control, name: 'registeredBranchId' }))
  const age = ageOn(useWatch({ control, name: 'dateOfBirth' }) || null, branchToday)

  // Pre-select a branch once /me has loaded, also with "All my branches" (defaultBranchId: active →
  // primary → first/only). Re-applied whenever the options change, so the native <select> never shows
  // "Select a branch…" while the form holds a stale or inaccessible id; a branch the user picked
  // themselves is kept as long as it is still offered.
  const branchKey = branches.map((b) => b.id).join(',')
  const fallbackBranch = defaultBranchId(me.data)
  useEffect(() => {
    if (!branchKey || isEmbedded) return
    const current = getValues('registeredBranchId')
    const next = current && branchKey.split(',').includes(current) ? current : fallbackBranch
    if (next) setValue('registeredBranchId', next)
  }, [branchKey, fallbackBranch, getValues, setValue, isEmbedded])

  const create = async (values: PatientFormValues, chosen: 'select' | 'book' = action, reason?: string) => {
    setFormError(null)
    setRetryValues(null)
    try {
      const created = await createPatient.mutateAsync(toCreatePatientRequest(values, reason))
      // The MRN is generated by the server; show it straight away.
      toast.success(`Patient registered. MRN ${created.mrn}`, { id: `registered-${created.id}` })
      await afterSave?.(created)
      if (embedded) {
        embedded.onCreated(created, chosen)
      } else if (origin.returnTo) {
        const back: ReturnedPatientState = { ...origin.returnState, pickedPatient: created }
        navigate(origin.returnTo, { replace: true, state: back })
      } else {
        navigate('/patients', { replace: true, state: { registered: created.mrn } })
      }
    } catch (error) {
      setDuplicates(null)
      // Cold server / timeout: never auto-retried; offer Retry (the MRN is generated server-side).
      const transient = transientWriteMessage(error, 'register the patient')
      if (transient) {
        setFormError(transient)
        setRetryValues(values)
        return
      }
      const fields = fieldErrors(error)
      for (const [field, message] of Object.entries(fields)) {
        const key = field === 'whatsapp' ? 'whatsappNumber' : field
        if (key in values) setError(key as keyof PatientFormValues, { message })
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

  // Same hospital: email, phone and ABHA block; a name match (even with no date of birth) needs a reason.
  // If the check itself fails, registration does not continue.
  const onSubmit = async (values: PatientFormValues, chosen: 'select' | 'book' = 'select') => {
    setFormError(null)
    setDuplicates(null)
    setDuplicateReason('')
    const request = toCreatePatientRequest(values)
    let matches: DuplicateCandidate[] = []
    try {
      matches = await apiClient.patients.duplicates({
        firstName: request.firstName,
        lastName: request.lastName,
        dateOfBirth: request.dateOfBirth,
        phone: request.phone,
        email: request.email,
        abhaNumber: request.abhaNumber,
      })
    } catch {
      setFormError('Could not check for existing patients. Registration did not continue.')
      return
    }
    if (duplicateMode(matches)) {
      setDuplicates({ matches, values })
      return
    }
    await create(values, chosen)
  }

  if (embedded) {
    const save = (chosen: 'select' | 'book') => {
      setAction(chosen)
      void handleSubmit((v) => onSubmit(v, chosen))()
    }
    // Enter in any field saves this form, never submits the surrounding booking form.
    const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
      if (e.key === 'Enter' && e.target instanceof HTMLInputElement && e.target.type !== 'checkbox') {
        e.preventDefault()
        save(embedded.canBook ? 'book' : 'select')
      } else if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        embedded.onCancel()
      }
    }
    return (
      // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- keyboard shortcuts for the fields inside
      <div
        role="group"
        aria-labelledby="quick-register-title"
        data-testid="quick-register"
        className="space-y-3 rounded-lg border border-gray-200 p-3 dark:border-dark-500"
        onKeyDown={onKeyDown}
      >
        <h3 id="quick-register-title" className="text-sm font-semibold text-gray-800 dark:text-dark-50">
          New patient <span className="font-normal text-gray-600 dark:text-dark-200">(MRN assigned on save)</span>
        </h3>
        {formError &&
          (retryValues ? (
            <RetryAlert message={formError} busy={createPatient.isPending} onRetry={() => void create(retryValues)} />
          ) : (
            <Alert tone="error">{formError}</Alert>
          ))}
        {(duplicates || liveMatches) && (
          <DuplicateWarning
            matches={(duplicates ?? { matches: liveMatches! }).matches}
            busy={creatingAnyway}
            proceedLabel="Create new anyway"
            reason={duplicateReason}
            onReasonChange={setDuplicateReason}
            focusOnShow={!!duplicates}
            onUseExisting={embedded.onUseExisting}
            onProceed={async () => {
              const values = duplicates?.values ?? getValues()
              setCreatingAnyway(true)
              try {
                await create(values, action, duplicateReason)
              } finally {
                setCreatingAnyway(false)
              }
            }}
            onDismiss={() => {
              setDuplicates(null)
              setLiveFetched(null)
              setDismissedLive(debouncedLive)
            }}
          />
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <FormField label="First name" autoComplete="off" error={errors.firstName?.message} {...register('firstName')} />
          <FormField label="Last name" autoComplete="off" error={errors.lastName?.message} {...register('lastName')} />
          <FormField
            label="Phone (optional)"
            type="tel"
            autoComplete="off"
            hint={`${countryCode ?? "The hospital's calling code"} is assumed when no country code is typed.`}
            error={errors.phone?.message}
            {...register('phone')}
          />
          <FormField
            label="Date of birth"
            type="date"
            min="1900-01-01"
            max={branchToday}
            error={errors.dateOfBirth?.message}
            {...register('dateOfBirth')}
          />
          <FormField
            label="ABHA number (optional)"
            inputMode="numeric"
            autoComplete="off"
            placeholder="XX-XXXX-XXXX-XXXX"
            error={errors.abhaNumber?.message}
            {...register('abhaNumber')}
          />
          <WhatsappFields control={control} register={register} errors={errors} />
        </div>
        {consent}
        <div className="flex flex-wrap gap-2">
          {embedded.canBook && (
            <Button onClick={() => save('book')} disabled={isSubmitting || creatingAnyway} data-testid="save-and-book">
              {isSubmitting && action === 'book' ? 'Saving…' : 'Save & book'}
            </Button>
          )}
          <Button
            variant={embedded.canBook ? 'secondary' : 'primary'}
            onClick={() => save('select')}
            disabled={isSubmitting || creatingAnyway}
            data-testid="save-patient"
          >
            {isSubmitting && action === 'select' ? 'Saving…' : 'Save patient'}
          </Button>
          <Button variant="secondary" onClick={embedded.onCancel} disabled={isSubmitting}>
            Cancel
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <Illustration name="person" size={64} />
          <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Register patient</h1>
        </div>
        <Link to={origin.returnTo ?? '/patients'} className="text-sm font-medium text-primary-600 hover:underline dark:text-primary-400">
          {origin.returnTo ? 'Back' : 'Back to patients'}
        </Link>
      </div>
      <Card>
        <p className="mb-4 text-sm text-gray-600 dark:text-dark-200">
          Registering in <strong>{activeTenant?.name ?? '—'}</strong>. The MRN is assigned automatically when you register.
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
              reason={duplicateReason}
              onReasonChange={setDuplicateReason}
              onProceed={async () => {
                setCreatingAnyway(true)
                try {
                  await create(duplicates.values, 'select', duplicateReason)
                } finally {
                  setCreatingAnyway(false)
                }
              }}
              onDismiss={() => setDuplicates(null)}
            />
          </div>
        )}
        <form noValidate aria-label="Register patient" onSubmit={handleSubmit((v) => onSubmit(v))} className="grid gap-4 sm:grid-cols-2">
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
            hint={age ? `Age: ${age}` : undefined}
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
          <FormField
            label="ABHA number (optional)"
            inputMode="numeric"
            autoComplete="off"
            placeholder="XX-XXXX-XXXX-XXXX"
            error={errors.abhaNumber?.message}
            {...register('abhaNumber')}
          />
          <WhatsappFields control={control} register={register} errors={errors} />
          {consent && <div className="sm:col-span-2">{consent}</div>}
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
