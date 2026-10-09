import { useEffect, useRef } from 'react'
import { Link } from 'react-router'
import { Button } from '../../components/ui/Button'
import type { DuplicateMatchReason, DuplicateCandidate } from '../../lib/api/types'

const REASON_LABEL: Record<DuplicateMatchReason, string> = {
  name_dob: 'same name and date of birth',
  phone: 'same phone number',
}

/** Possible existing records for the patient being registered: open one, or register anyway. */
export function DuplicateWarning({
  matches,
  busy,
  onProceed,
  onDismiss,
}: {
  matches: DuplicateCandidate[]
  busy: boolean
  onProceed: () => void
  onDismiss: () => void
}) {
  const headingRef = useRef<HTMLHeadingElement>(null)
  useEffect(() => headingRef.current?.focus(), [])

  return (
    <section
      aria-labelledby="duplicate-warning-title"
      data-testid="duplicate-warning"
      className="space-y-3 rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950"
    >
      <h2 id="duplicate-warning-title" ref={headingRef} tabIndex={-1} className="text-base font-semibold">
        Possible duplicate patient
      </h2>
      <p>
        {matches.length === 1 ? 'A patient' : `${matches.length} patients`} in this hospital may already be this person. Open the
        existing record instead of registering a duplicate, or register anyway if this is a different person.
      </p>
      <ul className="divide-y divide-amber-200 rounded border border-amber-200 bg-white">
        {matches.map((m) => (
          <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2" data-testid="duplicate-match">
            <span>
              <span className="font-mono">{m.mrn}</span> · {m.lastName}, {m.firstName} · {m.dateOfBirth ?? 'DOB unknown'}
              <span className="block text-xs text-slate-600">Matched on {(m.matchReasons ?? []).map((r) => REASON_LABEL[r] ?? r).join(' and ')}</span>
            </span>
            <Link to={`/patients/${m.id}`} className="text-brand-800 underline" aria-label={`Open existing record ${m.mrn}`}>
              Open existing record
            </Link>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Button onClick={onProceed} disabled={busy}>
          {busy ? 'Registering…' : 'Register anyway'}
        </Button>
        <Button variant="secondary" onClick={onDismiss} disabled={busy}>
          Review details
        </Button>
      </div>
    </section>
  )
}
