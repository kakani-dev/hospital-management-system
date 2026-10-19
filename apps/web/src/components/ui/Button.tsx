import type { ComponentPropsWithRef } from 'react'
import { Button as TxButton, type TailuxColor } from '@tailux/components/ui'

/**
 * HMS button API on top of the Tailux Button. The HMS variant names are kept so screens and tests
 * don't change: primary = filled primary, secondary = outlined neutral, ghost = flat neutral,
 * danger = filled error.
 */
type Variant = 'primary' | 'secondary' | 'ghost' | 'danger'

const map: Record<Variant, { color: TailuxColor; variant: 'filled' | 'outlined' | 'flat' }> = {
  primary: { color: 'primary', variant: 'filled' },
  secondary: { color: 'neutral', variant: 'outlined' },
  ghost: { color: 'neutral', variant: 'flat' },
  danger: { color: 'error', variant: 'filled' },
}

export function Button({
  variant = 'primary',
  className = '',
  type = 'button',
  ...props
}: Omit<ComponentPropsWithRef<'button'>, 'color'> & { variant?: Variant }) {
  const m = map[variant]
  // White on the base error tone is 3.1:1; the darker tone meets WCAG AA.
  const tone = variant === 'danger' ? 'bg-this-darker! hover:bg-this-darker/90!' : ''
  return <TxButton type={type} color={m.color} variant={m.variant} className={`gap-2 px-4 text-sm ${tone} ${className}`} {...props} />
}
