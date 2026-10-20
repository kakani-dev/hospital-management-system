import { useId, useState, type Ref } from 'react'
import { useNavigate } from 'react-router'
import clsx from 'clsx'
import { Badge, Input } from '@tailux/components/ui'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, usePatients, useRecentPatients } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { latestToday, localToday } from '../../lib/dates'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { exactMrnFirst, PATIENT_PICKER_MIN_CHARS, patientOptionLabel } from './patientLabel'
import type { PatientSummary } from '../../lib/api/types'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { prefillFromTerm, type RegisterPatientState, type RegisterReturn } from './registerReturn'

/**
 * Type-ahead patient picker (ARIA 1.2 combobox + listbox). Debounced POST /patients/search (the
 * term stays in the body). ↑/↓ move, Enter picks (and never submits the surrounding form while the
 * list is open), Esc closes then clears. When nothing matches, "Register new patient" opens the
 * register form pre-filled from the term and comes back here with the new patient selected.
 */
export function PatientPicker({
  value,
  onChange,
  label = 'Find patient',
  registerReturn,
  inputRef,
  shortcut = 'patient-search',
  onCreateNew,
  showRecent = false,
}: {
  value: PatientSummary | null
  onChange: (patient: PatientSummary | null) => void
  label?: string
  /** Enables "No match → Register new patient" (for users who may register). */
  registerReturn?: RegisterReturn
  inputRef?: Ref<HTMLInputElement>
  /** data-shortcut target name for the global keyboard shortcuts. */
  shortcut?: string
  /**
   * Inline quick-register (booking drawer): "+ New patient “<term>”" is always the last option (for
   * users with patients.create) and calls this instead of navigating to the register page.
   */
  onCreateNew?: (term: string) => void
  /** Show recent patients when the empty field gets focus (no extra tap needed). */
  showRecent?: boolean
}) {
  const navigate = useNavigate()
  const { has } = useCurrentContext()
  const [term, setTerm] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const debounced = useDebouncedValue(term, PATIENT_SEARCH_DEBOUNCE_MS)
  const inputId = useId()
  const listId = useId()
  const hintId = useId()
  const searching = debounced.trim().length >= PATIENT_PICKER_MIN_CHARS
  const results = usePatients(debounced, { enabled: searching })
  // Empty field + focus: the most recent patients (GET /patients?sort=recent), so the list shows on the first tap.
  const recentMode = showRecent && term.trim() === ''
  const recent = useRecentPatients(recentMode && open)
  const recentItems = recentMode ? (recent.data?.items ?? []).slice(0, 5) : []
  // Results for the text actually in the box (not a previous term, not mid-debounce).
  const fresh = searching && debounced === term && !results.isPending && !results.isPlaceholderData && !results.isError
  // Exact-MRN match first: typing a full MRN puts that patient at the top, and Enter picks it.
  const searched = exactMrnFirst(searching ? (results.data?.items ?? []) : [], debounced)
  const items = recentMode ? recentItems : searched.items
  const exact = recentMode ? undefined : searched.exact
  const canRegister = (!!registerReturn || !!onCreateNew) && has('patients.write')
  const typed = term.trim().length >= PATIENT_PICKER_MIN_CHARS
  // Inline mode: always offered as the last option once a term is typed; page mode: only on no match.
  // Only once results for this exact term are in, so a quick tap can't hit it instead of a match still loading.
  const offerRegister = canRegister && typed && fresh && (onCreateNew ? true : items.length === 0)
  const optionCount = items.length + (offerRegister ? 1 : 0)
  const expanded = open && (typed || (recentMode && recentItems.length > 0))
  const optionId = (i: number) => `${listId}-opt-${i}`
  // Ages are counted in the user's branch/hospital zone (never the workstation's).
  const { defaultZone } = useBranchTimeZones()
  const today = defaultZone ? localToday(new Date(), defaultZone) : latestToday()

  const pick = (p: PatientSummary) => {
    onChange(p)
    setTerm('')
    setOpen(false)
    setActive(-1)
  }
  const registerNew = () => {
    if (onCreateNew) {
      setOpen(false)
      setActive(-1)
      onCreateNew(term.trim())
      return
    }
    const state: RegisterPatientState = { returnTo: registerReturn!.to, returnState: registerReturn!.state, prefill: prefillFromTerm(term) }
    navigate('/patients/new', { state })
  }
  const choose = (index: number) => {
    if (index < items.length) pick(items[index]!)
    else if (offerRegister && index === items.length) registerNew()
  }

  return (
    <div className="relative space-y-2">
      <Input
        id={inputId}
        label={label}
        classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
        ref={inputRef}
        type="search"
        role="combobox"
        aria-expanded={expanded}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={expanded && active >= 0 && active < optionCount ? optionId(active) : undefined}
        aria-describedby={hintId}
        data-shortcut={shortcut}
        maxLength={PATIENT_SEARCH_MAX_LENGTH}
        value={term}
        placeholder="Name or MRN"
        autoComplete="off"
        onChange={(e) => {
          setTerm(e.target.value)
          setOpen(true)
          setActive(-1)
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={(e) => {
          if (e.altKey && e.code === 'KeyN' && canRegister) {
            // Alt+N from the picker registers with the typed name/MRN pre-filled (global Alt+N opens a blank form).
            e.preventDefault()
            e.stopPropagation()
            registerNew()
          } else if (e.key === 'ArrowDown') {
            e.preventDefault()
            setOpen(true)
            if (optionCount > 0) setActive((i) => Math.min(i + 1, optionCount - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            if (optionCount > 0) setActive((i) => Math.max(i - 1, 0))
          } else if (e.key === 'Home' && expanded && optionCount > 0) {
            e.preventDefault()
            setActive(0)
          } else if (e.key === 'End' && expanded && optionCount > 0) {
            e.preventDefault()
            setActive(optionCount - 1)
          } else if (e.key === 'Enter' && expanded) {
            // While the list is open Enter belongs to the list, never to the form.
            e.preventDefault()
            if (!fresh && !recentMode) return // results still belong to an older term
            if (active >= 0) choose(active)
            else if (optionCount === 1 || exact) choose(0)
          } else if (e.key === 'Escape') {
            if (expanded) {
              e.preventDefault()
              e.stopPropagation()
              setOpen(false)
              setActive(-1)
            } else if (term) {
              e.preventDefault()
              e.stopPropagation()
              setTerm('')
            }
          }
        }}
      />
      <p id={hintId} className="sr-only">
        Type at least {PATIENT_PICKER_MIN_CHARS} characters, then use the arrow keys and Enter to choose a patient.
      </p>
      {value && (
        <p className="text-sm text-gray-700 dark:text-dark-200" data-testid="picked-patient">
          Selected:{' '}
          <strong className="text-gray-800 dark:text-dark-50">
            {value.lastName}, {value.firstName}
          </strong>{' '}
          <span className="font-mono">{value.mrn}</span>{' '}
          <button
            type="button"
            className="font-medium text-primary-600 hover:underline dark:text-primary-400"
            onClick={() => onChange(null)}
          >
            Clear
          </button>
        </p>
      )}
      {/* Dropdown styled as the Tailux Combobox options panel (js/demo components/shared/form/Combobox). */}
      <div
        className={
          expanded
            ? 'rounded-lg border border-gray-300 bg-white py-1 shadow-lg shadow-gray-200/50 dark:border-dark-500 dark:bg-dark-750 dark:shadow-none'
            : 'hidden'
        }
        aria-busy={results.isFetching}
      >
        <div role="status" className="px-4 text-sm text-gray-600 dark:text-dark-200">
          {expanded && searching && results.isPending && <p className="py-2">Searching…</p>}
          {expanded && results.isError && <p className="py-2 text-error-darker dark:text-error-lighter">Patient search is unavailable.</p>}
          {expanded && fresh && items.length === 0 && <p className="py-2">No matching patients.</p>}
          {expanded && recentMode && <p className="pt-1 text-xs font-medium uppercase text-gray-500 dark:text-dark-300">Recent patients</p>}
        </div>
        <ul
          id={listId}
          role="listbox"
          aria-label={recentMode ? 'Recent patients' : 'Matching patients'}
          className={clsx('max-h-60 overflow-y-auto overflow-x-hidden', results.isPlaceholderData && 'opacity-60')}
        >
          {expanded &&
            items.map((p, i) => (
              // Keyboard is handled on the combobox input (aria-activedescendant pattern); options are not focusable.
              // eslint-disable-next-line jsx-a11y/click-events-have-key-events
              <li
                key={p.id}
                id={optionId(i)}
                role="option"
                aria-selected={i === active}
                data-testid="patient-option"
                className={clsx(
                  'relative cursor-pointer select-none px-4 py-2 text-sm transition-colors',
                  i === active
                    ? 'bg-primary-600 text-white dark:bg-primary-500'
                    : 'text-gray-800 hover:bg-gray-100 dark:text-dark-100 dark:hover:bg-dark-600',
                )}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pick(p)}
              >
                {patientOptionLabel(p, today)}
                {p === exact && (
                  <Badge color="primary" variant={i === active ? 'filled' : 'soft'} className="ml-2 align-middle text-tiny" data-testid="exact-mrn-badge">
                    Exact MRN
                  </Badge>
                )}
              </li>
            ))}
          {expanded && offerRegister && (
            // eslint-disable-next-line jsx-a11y/click-events-have-key-events -- keyboard via the combobox input
            <li
              id={optionId(items.length)}
              role="option"
              aria-selected={active === items.length}
              data-testid="register-new-patient"
              className={clsx(
                'relative cursor-pointer select-none border-t border-gray-200 px-4 py-2 text-sm font-medium transition-colors dark:border-dark-500',
                active === items.length
                  ? 'bg-primary-600 text-white dark:bg-primary-500'
                  : 'text-primary-600 hover:bg-gray-100 dark:text-primary-400 dark:hover:bg-dark-600',
              )}
              onMouseDown={(e) => e.preventDefault()}
              onClick={registerNew}
            >
              {onCreateNew ? <>+ New patient “{term.trim()}”</> : <>No match: register new patient “{term.trim()}” (Alt+N)</>}
            </li>
          )}
        </ul>
      </div>
    </div>
  )
}
