import { forwardRef, useId, type ReactNode, type SelectHTMLAttributes } from 'react'
import { Select } from '@tailux/components/ui'

interface SelectFieldProps extends Omit<SelectHTMLAttributes<HTMLSelectElement>, 'prefix'> {
  label: string
  error?: string
  children: ReactNode
}

/** Labelled native select (keeps selectOption/getByLabel working): the Tailux Select. */
export const SelectField = forwardRef<HTMLSelectElement, SelectFieldProps>(function SelectField(
  { label, error, id, children, ...props },
  ref,
) {
  const generatedId = useId()
  const selectId = id ?? generatedId
  const errorId = `${selectId}-error`
  return (
    <Select
      ref={ref}
      id={selectId}
      label={label}
      aria-invalid={error ? true : undefined}
      aria-describedby={error ? errorId : undefined}
      classNames={{ root: '', label: 'font-medium text-gray-800 dark:text-dark-100' }}
      error={
        error ? (
          <span id={errorId} role="alert">
            {error}
          </span>
        ) : undefined
      }
      {...props}
    >
      {children}
    </Select>
  )
})
