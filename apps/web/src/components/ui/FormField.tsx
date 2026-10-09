import { useId, type InputHTMLAttributes } from 'react'
import { Input } from '@tailux/components/ui'

interface FormFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'prefix'> {
  label: string
  error?: string
  hint?: string
}

/** Labelled text input: the Tailux Input with HMS error/hint wiring (aria-describedby, role="alert"). */
export function FormField({ label, error, hint, id, ...inputProps }: FormFieldProps) {
  const generatedId = useId()
  const inputId = id ?? generatedId
  const errorId = `${inputId}-error`
  const hintId = `${inputId}-hint`
  const describedBy = [hint ? hintId : null, error ? errorId : null].filter(Boolean).join(' ') || undefined

  return (
    <Input
      id={inputId}
      label={label}
      aria-invalid={error ? true : undefined}
      aria-describedby={describedBy}
      classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
      error={
        error ? (
          <span id={errorId} role="alert">
            {error}
          </span>
        ) : undefined
      }
      description={hint ? <span id={hintId}>{hint}</span> : undefined}
      {...inputProps}
    />
  )
}
