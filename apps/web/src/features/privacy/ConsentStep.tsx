import type { PrivacyPurpose } from '../../lib/api/types'

/**
 * Purpose toggles for a privacy notice. Nothing else in the app is a consent block:
 * treatment and billing are not choices, and each purpose here is optional.
 * RegisterPatientPage cannot be edited in this slice. It needs an optional
 * `consent?: ReactNode` rendered above Save so this step can sit on registration.
 */
export function ConsentStep({
  purposes,
  value,
  onChange,
  disabled = false,
}: {
  purposes: PrivacyPurpose[]
  value: Record<string, boolean>
  onChange: (purpose: string, granted: boolean) => void
  disabled?: boolean
}) {
  return (
    <fieldset className="space-y-2" disabled={disabled}>
      <legend className="text-sm font-medium text-gray-800 dark:text-dark-100">Optional uses</legend>
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Care and billing do not need a tick. You can say no to any of these, and you can change your mind later.
      </p>
      {purposes.map((purpose) => (
        <label key={purpose.code} className="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            className="mt-1"
            checked={!!value[purpose.code]}
            onChange={(event) => onChange(purpose.code, event.target.checked)}
          />
          <span>{purpose.label}</span>
        </label>
      ))}
    </fieldset>
  )
}
