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
  onUseExisting,
  proceedLabel = 'Register anyway',
}: {
  matches: DuplicateCandidate[]
  busy: boolean
  onProceed: () => void
  onDismiss: () => void
  /** Embedded (booking drawer): pick the existing record in place instead of opening it. */
  onUseExisting?: (match: DuplicateCandidate) => void
  proceedLabel?: string
}) {
  const headingRef = useRef<HTMLHeadingElement>(null)
  useEffect(() => headingRef.current?.focus(), [])

  return (
    <section
      aria-labelledby="duplicate-warning-title"
      data-testid="duplicate-warning"
      className="this:warning space-y-3 rounded-lg border border-this/30 bg-this-darker/10 p-4 text-sm text-this-darker dark:border-this-lighter/30 dark:bg-this-lighter/10 dark:text-this-lighter"
    >
      <h2 id="duplicate-warning-title" ref={headingRef} tabIndex={-1} className="text-base font-semibold">
        Possible duplicate patient
      </h2>
      <p>
        {matches.length === 1 ? 'A patient' : `${matches.length} patients`} in this hospital may already be this person. Open the existing
        record instead of registering a duplicate, or register anyway if this is a different person.
      </p>
      <ul className="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white text-gray-800 dark:divide-dark-500 dark:border-dark-500 dark:bg-dark-750 dark:text-dark-100">
        {matches.map((m) => (
          <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2" data-testid="duplicate-match">
            <span>
              <span className="font-mono">{m.mrn}</span> · {m.lastName}, {m.firstName} · {m.dateOfBirth ?? 'DOB unknown'}
              <span className="block text-xs text-gray-500 dark:text-dark-300">
                Matched on {(m.matchReasons ?? []).map((r) => REASON_LABEL[r] ?? r).join(' and ')}
              </span>
            </span>
            {onUseExisting ? (
              <Button variant="secondary" onClick={() => onUseExisting(m)} aria-label={`Use existing record ${m.mrn}`} data-testid="use-existing">
                Use existing
              </Button>
            ) : (
            <Link
              to={`/patients/${m.id}`}
              className="font-medium text-primary-600 hover:underline dark:text-primary-400"
              aria-label={`Open existing record ${m.mrn}`}
            >
              Open existing record
            </Link>
            )}
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Button onClick={onProceed} disabled={busy}>
          {busy ? 'Registering…' : proceedLabel}
        </Button>
        <Button variant="secondary" onClick={onDismiss} disabled={busy}>
          Review details
        </Button>
      </div>
    </section>
  )
}
