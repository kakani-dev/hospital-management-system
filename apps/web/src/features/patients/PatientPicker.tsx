import { useId, useState, type Ref } from 'react'
import { useNavigate } from 'react-router'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, usePatients } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { localToday } from '../../lib/dates'
import { PATIENT_PICKER_MIN_CHARS, patientOptionLabel } from './patientLabel'
import { can } from '../../lib/permissions'
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
}: {
  value: PatientSummary | null
  onChange: (patient: PatientSummary | null) => void
  label?: string
  /** Enables "No match → Register new patient" (for users who may register). */
  registerReturn?: RegisterReturn
  inputRef?: Ref<HTMLInputElement>
  /** data-shortcut target name for the global keyboard shortcuts. */
  shortcut?: string
}) {
  const navigate = useNavigate()
  const { roles } = useCurrentContext()
  const [term, setTerm] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const debounced = useDebouncedValue(term, PATIENT_SEARCH_DEBOUNCE_MS)
  const inputId = useId()
  const listId = useId()
  const hintId = useId()
  const searching = debounced.trim().length >= PATIENT_PICKER_MIN_CHARS
  const results = usePatients(debounced, { enabled: searching })
  // Results for the text actually in the box (not a previous term, not mid-debounce).
  const fresh = searching && debounced === term && !results.isPending && !results.isPlaceholderData && !results.isError
  const items = searching ? (results.data?.items ?? []) : []
  const canRegister = !!registerReturn && can(roles, 'patients.write')
  const offerRegister = canRegister && fresh && items.length === 0
  const optionCount = items.length + (offerRegister ? 1 : 0)
  const expanded = open && term.trim().length >= PATIENT_PICKER_MIN_CHARS
  const optionId = (i: number) => `${listId}-opt-${i}`
  const today = localToday()

  const pick = (p: PatientSummary) => {
    onChange(p)
    setTerm('')
    setOpen(false)
    setActive(-1)
  }
  const registerNew = () => {
    const state: RegisterPatientState = { returnTo: registerReturn!.to, returnState: registerReturn!.state, prefill: prefillFromTerm(term) }
    navigate('/patients/new', { state })
  }
  const choose = (index: number) => {
    if (index < items.length) pick(items[index]!)
    else if (offerRegister && index === items.length) registerNew()
  }

  return (
    <div className="space-y-2">
      <label htmlFor={inputId} className="block text-sm font-medium text-slate-800">
        {label}
      </label>
      <input
        id={inputId}
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
            if (!fresh) return // results still belong to an older term
            if (active >= 0) choose(active)
            else if (optionCount === 1) choose(0)
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
        className="block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
      />
      <p id={hintId} className="sr-only">
        Type at least {PATIENT_PICKER_MIN_CHARS} characters, then use the arrow keys and Enter to choose a patient.
      </p>
      {value && (
        <p className="text-sm" data-testid="picked-patient">
          Selected: <strong>{value.lastName}, {value.firstName}</strong> <span className="font-mono">{value.mrn}</span>{' '}
          <button type="button" className="text-brand-800 underline" onClick={() => onChange(null)}>
            Clear
          </button>
        </p>
      )}
      <div className={expanded ? 'rounded border border-slate-200' : 'hidden'} aria-busy={results.isFetching}>
        <div role="status" className="px-3 text-sm text-slate-600">
          {expanded && searching && results.isPending && <p className="py-2">Searching…</p>}
          {expanded && results.isError && <p className="py-2 text-red-700">Patient search is unavailable.</p>}
          {expanded && fresh && items.length === 0 && <p className="py-2">No matching patients.</p>}
        </div>
        <ul id={listId} role="listbox" aria-label="Matching patients" className={`max-h-56 overflow-y-auto ${results.isPlaceholderData ? 'opacity-60' : ''}`}>
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
                className={`cursor-pointer px-3 py-2 text-sm ${i === active ? 'bg-brand-50 outline outline-1 outline-brand-600' : 'hover:bg-slate-50'}`}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pick(p)}
              >
                {patientOptionLabel(p, today)}
              </li>
            ))}
          {expanded && offerRegister && (
            // eslint-disable-next-line jsx-a11y/click-events-have-key-events -- keyboard via the combobox input
            <li
              id={optionId(items.length)}
              role="option"
              aria-selected={active === items.length}
              data-testid="register-new-patient"
              className={`cursor-pointer border-t border-slate-100 px-3 py-2 text-sm font-medium text-brand-800 ${active === items.length ? 'bg-brand-50 outline outline-1 outline-brand-600' : 'hover:bg-slate-50'}`}
              onMouseDown={(e) => e.preventDefault()}
              onClick={registerNew}
            >
              No match: register new patient “{term.trim()}” (Alt+N)
            </li>
          )}
        </ul>
      </div>
    </div>
  )
}

