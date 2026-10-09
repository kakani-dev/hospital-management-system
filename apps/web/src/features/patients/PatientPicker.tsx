import { useId, useState } from 'react'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, usePatients } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import type { PatientSummary } from '../../lib/api/types'

/**
 * Find-and-pick a patient: debounced POST /patients/search (the term stays in the body), results
 * as a radio group. Nothing is fetched until something is typed.
 */
export function PatientPicker({
  value,
  onChange,
  label = 'Find patient',
}: {
  value: PatientSummary | null
  onChange: (patient: PatientSummary | null) => void
  label?: string
}) {
  const [term, setTerm] = useState('')
  const debounced = useDebouncedValue(term, PATIENT_SEARCH_DEBOUNCE_MS)
  const inputId = useId()
  const resultsName = useId()
  const hasTerm = debounced.trim().length > 0
  const results = usePatients(debounced, { enabled: hasTerm })

  return (
    <div className="space-y-2">
      <label htmlFor={inputId} className="block text-sm font-medium text-slate-800">
        {label}
      </label>
      <input
        id={inputId}
        type="search"
        maxLength={PATIENT_SEARCH_MAX_LENGTH}
        value={term}
        placeholder="Name or MRN"
        autoComplete="off"
        onChange={(e) => setTerm(e.target.value)}
        className="block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
      />
      {value && (
        <p className="text-sm" data-testid="picked-patient">
          Selected: <strong>{value.lastName}, {value.firstName}</strong> <span className="font-mono">{value.mrn}</span>{' '}
          <button type="button" className="text-brand-800 underline" onClick={() => onChange(null)}>
            Clear
          </button>
        </p>
      )}
      {hasTerm && (
        <fieldset className="max-h-56 overflow-y-auto rounded border border-slate-200" aria-busy={results.isFetching}>
          <legend className="sr-only">Matching patients</legend>
          {results.isPending && <p className="px-3 py-2 text-sm text-slate-600">Searching…</p>}
          {results.isError && <p className="px-3 py-2 text-sm text-red-700">Patient search is unavailable.</p>}
          {results.data?.items.length === 0 && <p className="px-3 py-2 text-sm text-slate-600">No matching patients.</p>}
          {results.data?.items.map((p) => (
            <label key={p.id} className="flex cursor-pointer items-center gap-2 px-3 py-2 text-sm hover:bg-slate-50" data-testid="patient-option">
              <input type="radio" name={resultsName} checked={value?.id === p.id} onChange={() => onChange(p)} />
              <span>
                {p.lastName}, {p.firstName} · <span className="font-mono">{p.mrn}</span> · {p.dateOfBirth ?? 'DOB unknown'}
              </span>
            </label>
          ))}
        </fieldset>
      )}
    </div>
  )
}
