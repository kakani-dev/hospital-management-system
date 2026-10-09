// Type declarations for the Tailux starter UI components (plain JS, ported verbatim from
// js/starter/src/components/ui, PropTypes removed). The shapes mirror the original PropTypes.
import type {
  ComponentPropsWithRef,
  CSSProperties,
  ElementType,
  ForwardRefExoticComponent,
  ReactNode,
  RefAttributes,
} from 'react'

export type TailuxColor = 'neutral' | 'primary' | 'secondary' | 'info' | 'success' | 'warning' | 'error'
type Poly = { component?: ElementType; [extra: `data-${string}`]: unknown }
type FC<P, E = HTMLElement> = ForwardRefExoticComponent<P & RefAttributes<E>>

export type ButtonProps = Omit<ComponentPropsWithRef<'button'>, 'color' | 'ref'> &
  Poly & {
    color?: TailuxColor
    variant?: 'filled' | 'soft' | 'outlined' | 'flat'
    isIcon?: boolean
    unstyled?: boolean
    isGlow?: boolean
    to?: string
    end?: boolean
  }
export declare const Button: FC<ButtonProps, HTMLButtonElement>

export type BadgeProps = Omit<ComponentPropsWithRef<'div'>, 'color' | 'ref'> &
  Poly & { color?: TailuxColor; variant?: 'filled' | 'outlined' | 'soft'; unstyled?: boolean; isGlow?: boolean }
export declare const Badge: FC<BadgeProps>

export type BoxProps = Omit<ComponentPropsWithRef<'div'>, 'ref'> & Poly & Record<string, unknown>
export declare const Box: FC<BoxProps>

export type CardProps = Omit<ComponentPropsWithRef<'div'>, 'ref'> & Poly & { skin?: 'none' | 'bordered' | 'shadow' } & Record<string, unknown>
export declare const Card: FC<CardProps>

export declare const Skeleton: FC<Omit<ComponentPropsWithRef<'div'>, 'ref'> & { animate?: boolean }>

type SpinnerProps = Omit<ComponentPropsWithRef<'div'>, 'color' | 'ref'> & {
  animate?: boolean
  isElastic?: boolean
  disabled?: boolean
  color?: TailuxColor
  unstyled?: boolean
  variant?: 'default' | 'soft' | 'innerDot'
}
export declare const Spinner: FC<SpinnerProps>
export declare const GhostSpinner: FC<Omit<SpinnerProps, 'color' | 'unstyled'>>

export declare const Collapse: FC<
  Omit<ComponentPropsWithRef<'div'>, 'ref'> & {
    in?: boolean
    transitionDuration?: number
    transitionTimingFunction?: string
    style?: CSSProperties
    onTransitionEnd?: () => void
    min?: string
  }
>

type ClassNames = Partial<Record<'root' | 'label' | 'labelText' | 'wrapper' | 'input' | 'select' | 'prefix' | 'suffix' | 'description' | 'error', string>>
type FieldCommon = {
  label?: ReactNode
  description?: ReactNode
  error?: boolean | ReactNode
  classNames?: ClassNames
  unstyled?: boolean
  rootProps?: ComponentPropsWithRef<'div'>
  labelProps?: ComponentPropsWithRef<'label'>
  component?: ElementType
}
export type InputProps = Omit<ComponentPropsWithRef<'input'>, 'prefix' | 'ref'> &
  FieldCommon & { prefix?: ReactNode; suffix?: ReactNode }
export declare const Input: FC<InputProps, HTMLInputElement>

export type SelectProps = Omit<ComponentPropsWithRef<'select'>, 'prefix' | 'ref'> &
  FieldCommon & {
    prefix?: ReactNode
    suffix?: ReactNode
    data?: Array<string | number | { label: ReactNode; value: string | number; disabled?: boolean }>
  }
export declare const Select: FC<SelectProps, HTMLSelectElement>

export type TextareaProps = Omit<ComponentPropsWithRef<'textarea'>, 'ref'> & FieldCommon
export declare const Textarea: FC<TextareaProps, HTMLTextAreaElement>

type CheckProps = Omit<ComponentPropsWithRef<'input'>, 'color' | 'ref'> & {
  variant?: 'outlined' | 'basic'
  unstyled?: boolean
  color?: Exclude<TailuxColor, 'neutral'>
  classNames?: Partial<Record<'label' | 'labelText' | 'input', string>>
  label?: ReactNode
  labelProps?: ComponentPropsWithRef<'label'>
}
export declare const Checkbox: FC<CheckProps & { indeterminate?: boolean }, HTMLInputElement>
export declare const Radio: FC<CheckProps, HTMLInputElement>
export declare function InputErrorMsg(props: { when?: unknown; children?: ReactNode; className?: string }): ReactNode

export declare const Pagination: FC<{
  total: number
  value?: number
  defaultValue?: number
  onChange?: (page: number) => void
  disabled?: boolean
  getItemProps?: (page: number) => Record<string, unknown>
  className?: string
  classNames?: Partial<Record<'root' | 'control' | 'controlIcon' | 'icon' | 'dots', string>>
  siblings?: number
  boundaries?: number
  children?: ReactNode
  onNextPage?: () => void
  onPreviousPage?: () => void
  onFirstPage?: () => void
  onLastPage?: () => void
}>
type EdgeProps = Omit<ComponentPropsWithRef<'button'>, 'ref'> & { Icon?: ElementType }
export declare const PaginationNext: FC<EdgeProps, HTMLButtonElement>
export declare const PaginationPrevious: FC<EdgeProps, HTMLButtonElement>
export declare const PaginationFirst: FC<EdgeProps, HTMLButtonElement>
export declare const PaginationLast: FC<EdgeProps, HTMLButtonElement>
export declare function PaginationItems(props: Record<string, unknown>): ReactNode

export declare const Table: FC<
  Omit<ComponentPropsWithRef<'table'>, 'ref'> & Poly & { hoverable?: boolean; zebra?: boolean; dense?: boolean; sticky?: boolean },
  HTMLTableElement
>
type TagProps<T extends 'thead' | 'tbody' | 'tfoot' | 'tr' | 'th' | 'td'> = Omit<ComponentPropsWithRef<T>, 'ref'> & Poly
export declare const THead: FC<TagProps<'thead'>, HTMLTableSectionElement>
export declare const TBody: FC<TagProps<'tbody'>, HTMLTableSectionElement>
export declare const TFoot: FC<TagProps<'tfoot'>, HTMLTableSectionElement>
export declare const Tr: FC<TagProps<'tr'>, HTMLTableRowElement>
export declare const Th: FC<TagProps<'th'>, HTMLTableCellElement>
export declare const Td: FC<TagProps<'td'>, HTMLTableCellElement>

export declare const Avatar: FC<
  Omit<ComponentPropsWithRef<'div'>, 'ref'> & {
    component?: ElementType
    imgComponent?: ElementType
    alt?: string
    loading?: 'auto' | 'lazy' | 'eager'
    imgProps?: Record<string, unknown>
    src?: string
    srcSet?: string
    name?: string
    initialColor?: TailuxColor | 'auto'
    initialVariant?: 'filled' | 'soft'
    initialProps?: Record<string, unknown>
    classNames?: Partial<Record<'root' | 'display' | 'image' | 'initial', string>>
    size?: number
    indicator?: ReactNode
  }
>
export declare const AvatarDot: FC<
  Omit<ComponentPropsWithRef<'div'>, 'color' | 'ref'> & { color?: TailuxColor; isPing?: boolean }
>
