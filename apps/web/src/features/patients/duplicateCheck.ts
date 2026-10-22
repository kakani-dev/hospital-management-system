import type { DuplicateCandidate } from '../../lib/api/types'

const HARD: ReadonlySet<string> = new Set(['phone', 'email', 'abha'])

/** Hard matches block a second chart. A name match (with or without a date of birth) only warns. */
export function duplicateMode(matches: DuplicateCandidate[]): 'hard' | 'name' | null {
  const reasons = matches.flatMap((m) => m.matchReasons ?? [])
  if (reasons.some((r) => HARD.has(r))) return 'hard'
  if (reasons.some((r) => r === 'name' || r === 'name_dob')) return 'name'
  return null
}
