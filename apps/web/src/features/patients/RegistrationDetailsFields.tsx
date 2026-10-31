import type { FieldErrors, UseFormRegister } from 'react-hook-form'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import type { RegistrationSettings } from '../../lib/api/types'
import { BLOOD_GROUPS, REFERRAL_LABELS, REFERRAL_SOURCES, type DetailsFormValues } from './patientSchema'

type WithDetails = { details?: DetailsFormValues }

/**
 * #58: address, emergency contact, guardian, blood group and referral, inline on the same form
 * (a native <details>: Enter/Space toggles it, no drawer or new page). It opens by itself when the
 * tenant's rules need something (a minor, or address / emergency contact made mandatory) or a field
 * in it has an error, so the desk never has to hunt for why Save was refused.
 */
export function RegistrationDetailsFields({
  register,
  errors,
  settings,
  ageYears,
  referralSource,
}: {
  register: UseFormRegister<WithDetails>
  errors: FieldErrors<WithDetails>
  settings?: RegistrationSettings
  /** Age from DOB or the typed age; null when unknown (unidentified emergency patient). */
  ageYears: number | null
  referralSource?: string
}) {
  const e = errors.details ?? {}
  const guardianNeeded = !!settings && settings.guardianRequiredBelowAgeYears > 0 && ageYears !== null && ageYears < settings.guardianRequiredBelowAgeYears
  const referrerNeeded = (settings?.referredByRequiredForReferrals ?? true) && (referralSource === 'doctor' || referralSource === 'hospital')
  const mustOpen = guardianNeeded || !!settings?.addressRequired || !!settings?.emergencyContactRequired || Object.keys(e).length > 0
  const req = (on: boolean, label: string) => (on ? label : `${label} (optional)`)
  return (
    <details className="group sm:col-span-2 rounded border border-gray-200 px-3 py-2 dark:border-dark-500" open={mustOpen || undefined} data-testid="patient-more-details">
      <summary className="cursor-pointer text-sm font-medium" data-testid="patient-more-details-toggle">
        More details{guardianNeeded ? ' · guardian needed (minor)' : ''}
      </summary>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        {guardianNeeded && (
          <>
            <FormField label="Guardian name" data-testid="patient-guardian-name" error={e.guardianName?.message} {...register('details.guardianName')} />
            <FormField label="Guardian relation (optional)" placeholder="Mother, Father…" data-testid="patient-guardian-relation" error={e.guardianRelation?.message} {...register('details.guardianRelation')} />
          </>
        )}
        <FormField label={req(!!settings?.addressRequired, 'Address')} autoComplete="street-address" data-testid="patient-address-line" error={e.addressLine?.message} {...register('details.addressLine')} />
        <FormField label={req(!!settings?.addressRequired, 'PIN code')} inputMode="numeric" maxLength={7} autoComplete="postal-code" data-testid="patient-pin-code" error={e.pinCode?.message} {...register('details.pinCode')} />
        <FormField label="City / village (optional)" data-testid="patient-city" error={e.city?.message} {...register('details.city')} />
        <FormField label="District (optional)" data-testid="patient-district" error={e.district?.message} {...register('details.district')} />
        <FormField label="State (optional)" data-testid="patient-state" error={e.state?.message} {...register('details.state')} />
        <FormField label={req(!!settings?.emergencyContactRequired, 'Emergency contact name')} data-testid="patient-emergency-name" error={e.emergencyContactName?.message} {...register('details.emergencyContactName')} />
        <FormField label={req(!!settings?.emergencyContactRequired, 'Emergency contact phone')} inputMode="tel" data-testid="patient-emergency-phone" error={e.emergencyContactPhone?.message} {...register('details.emergencyContactPhone')} />
        <FormField label="Relation (optional)" placeholder="Spouse, Son…" data-testid="patient-emergency-relation" error={e.emergencyContactRelation?.message} {...register('details.emergencyContactRelation')} />
        <SelectField label="Blood group (optional)" data-testid="patient-blood-group" error={e.bloodGroup?.message} {...register('details.bloodGroup')}>
          <option value="">Not known</option>
          {BLOOD_GROUPS.map((g) => (
            <option key={g} value={g}>{g}</option>
          ))}
        </SelectField>
        <SelectField label="Came via" data-testid="patient-referral-source" error={e.referralSource?.message} {...register('details.referralSource')}>
          {REFERRAL_SOURCES.map((r) => (
            <option key={r} value={r}>{REFERRAL_LABELS[r]}</option>
          ))}
        </SelectField>
        {referralSource && referralSource !== 'walk_in' && referralSource !== 'self' && (
          <FormField label={req(referrerNeeded, 'Referred by')} placeholder="Doctor / hospital / camp" data-testid="patient-referred-by" error={e.referredBy?.message} {...register('details.referredBy')} />
        )}
      </div>
    </details>
  )
}
