import { useWatch, type Control, type FieldErrors, type UseFormRegister } from 'react-hook-form'
import { Checkbox } from '@tailux/components/ui'
import { FormField } from '../../components/ui/FormField'
import type { PatientFormValues } from './patientSchema'

/**
 * "WhatsApp number" section for the register / edit forms (demo2 Checkbox + FormField): checked by
 * default = the phone number is the WhatsApp number (stored once); unticking reveals a separate input.
 */
export function WhatsappFields({
  control,
  register,
  errors,
}: {
  control: Control<PatientFormValues>
  register: UseFormRegister<PatientFormValues>
  errors: FieldErrors<PatientFormValues>
}) {
  const same = useWatch({ control, name: 'whatsappSameAsPhone' })
  return (
    <fieldset className="space-y-3 sm:col-span-2" data-testid="whatsapp-fields">
      <legend className="text-sm font-medium text-gray-800 dark:text-dark-100">WhatsApp number</legend>
      <Checkbox label="Same as phone number" classNames={{ labelText: 'text-sm' }} {...register('whatsappSameAsPhone')} />
      {!same && (
        <FormField
          label="WhatsApp number"
          type="tel"
          autoComplete="off"
          hint="Leave empty if the patient has no WhatsApp."
          error={errors.whatsappNumber?.message}
          {...register('whatsappNumber')}
        />
      )}
    </fieldset>
  )
}
