import { forwardRef, useId, useMemo, useState, type ComponentProps } from 'react'
import { Combobox, ComboboxButton, ComboboxInput, ComboboxOption, ComboboxOptions } from '@headlessui/react'
import { ChevronDownIcon } from '@heroicons/react/20/solid'
import { clsx } from 'clsx'
import { Input } from '@tailux/components/ui'
import { filterZones, ianaZones, matchZone, zoneOffsetLabel } from '../../lib/timeZones'

type ZoneInputProps = ComponentProps<typeof Input> & { 'data-describedby'?: string; 'data-invalid'?: boolean }

/**
 * Headless UI's ComboboxInput writes its own (empty) aria-describedby / aria-invalid over ours, so the
 * hint/error wiring travels in data-* props and is applied last here.
 */
const ZoneInput = forwardRef<HTMLInputElement, ZoneInputProps>(function ZoneInput(
  { 'data-describedby': describedBy, 'data-invalid': invalid, ...rest },
  ref,
) {
  return <Input ref={ref} {...rest} aria-describedby={describedBy} aria-invalid={invalid ? true : undefined} />
})

export interface TimeZoneFieldProps {
  label: string
  value: string
  onChange: (zone: string) => void
  onBlur?: () => void
  name?: string
  hint?: string
  error?: string
  disabled?: boolean
  id?: string
}

/**
 * Searchable IANA time zone picker: the Tailux Combobox (js/demo components/shared/form/Combobox,
 * Headless UI) over Intl.supportedValuesOf('timeZone') with a static fallback list. Replaces the
 * input + <datalist>, which mobile Chrome renders as an empty dropdown.
 *
 * Only listed zones can be chosen. Typing the exact id ("asia/dubai", "Asia Dubai") selects it as
 * well; any other text reverts to the current zone when the field is left. The server stays the validator.
 * The option panel overlays the content below (absolute, not portalled): it stays inside a drawer's
 * scroll area on a phone, and closing it never shifts the layout under a pending tap.
 */
export const TimeZoneField = forwardRef<HTMLInputElement, TimeZoneFieldProps>(function TimeZoneField(
  { label, value, onChange, onBlur, name, hint, error, disabled, id },
  ref,
) {
  const zones = useMemo(() => ianaZones(), [])
  const offsets = useMemo(() => {
    const now = new Date()
    return new Map(zones.map((z) => [z, zoneOffsetLabel(z, now)] as const))
  }, [zones])
  const [query, setQuery] = useState('')
  const filtered = useMemo(() => filterZones(query, zones, offsets), [query, zones, offsets])

  const generatedId = useId()
  const inputId = id ?? generatedId
  const hintId = `${inputId}-hint`
  const errorId = `${inputId}-error`
  const describedBy = [hint ? hintId : null, error ? errorId : null].filter(Boolean).join(' ') || undefined

  const commit = (zone: string | null) => {
    if (zone && zone !== value) onChange(zone)
    setQuery('')
  }

  return (
    <Combobox<string | null> value={value || null} onChange={commit} onClose={() => setQuery('')} immediate disabled={disabled}>
      {({ open }) => (
        <div data-testid="time-zone-field" className="relative">
          <ComboboxInput
            as={ZoneInput}
            ref={ref}
            id={inputId}
            name={name}
            label={label}
            autoComplete="off"
            spellCheck={false}
            enterKeyHint="done"
            placeholder="Search, e.g. Kolkata or +05:30"
            data-invalid={!!error}
            data-describedby={describedBy}
            classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
            displayValue={(zone: string | null) => zone ?? ''}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) => {
              setQuery(e.target.value)
              // An exactly typed zone counts at once (Save may be tapped without leaving the field).
              const exact = matchZone(e.target.value, zones)
              if (exact && exact !== value) onChange(exact)
            }}
            // Typing replaces the current zone instead of appending to it.
            onFocus={(e: React.FocusEvent<HTMLInputElement>) => e.target.select()}
            onBlur={(e: React.FocusEvent<HTMLInputElement>) => {
              commit(matchZone(e.target.value, zones))
              onBlur?.()
            }}
            error={
              error ? (
                <span id={errorId} role="alert">
                  {error}
                </span>
              ) : undefined
            }
            description={hint ? <span id={hintId}>{hint}</span> : undefined}
            suffix={
              <ComboboxButton aria-label="Show list" className="flex size-full items-center justify-center">
                <ChevronDownIcon className={clsx('size-5 transition-transform', open && 'rotate-180')} aria-hidden="true" />
              </ComboboxButton>
            }
          />
          <ComboboxOptions
            data-testid="time-zone-options"
            modal={false}
            className="absolute inset-x-0 z-20 mt-1 max-h-60 overflow-y-auto overflow-x-hidden rounded-lg border border-gray-300 bg-white py-1 shadow-lg shadow-gray-200/50 outline-hidden dark:border-dark-500 dark:bg-dark-750 dark:shadow-none"
          >
            {filtered.length === 0 ? (
              <div className="px-4 py-2 text-sm text-gray-800 dark:text-dark-100">No time zone matches “{query.trim()}”.</div>
            ) : (
              filtered.map((zone) => (
                <ComboboxOption
                  key={zone}
                  value={zone}
                  className={({ focus, selected }) =>
                    clsx(
                      'relative flex cursor-pointer select-none items-baseline justify-between gap-3 px-4 py-2.5 text-sm outline-hidden transition-colors',
                      selected
                        ? 'bg-primary-600 font-medium text-white'
                        : ['text-gray-800 dark:text-dark-100', focus && 'bg-gray-100 dark:bg-dark-600'],
                    )
                  }
                >
                  {({ selected }) => (
                    <>
                      <span className="truncate">{zone}</span>
                      {offsets.get(zone) && (
                        <span className={clsx('shrink-0 text-xs tabular-nums', selected ? 'text-white' : 'text-gray-600 dark:text-dark-200')}>
                          {offsets.get(zone)}
                        </span>
                      )}
                    </>
                  )}
                </ComboboxOption>
              ))
            )}
          </ComboboxOptions>
        </div>
      )}
    </Combobox>
  )
})
