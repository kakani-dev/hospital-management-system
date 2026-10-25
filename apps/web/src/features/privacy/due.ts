const TEN_DAYS_MS = 10 * 24 * 60 * 60 * 1000

/** True when the DPDP due date is still ahead and falls inside the next 10 days. */
export function isDueSoon(dueAt: string, now: Date = new Date()): boolean {
  const due = Date.parse(dueAt)
  if (Number.isNaN(due)) return false
  const left = due - now.getTime()
  return left > 0 && left <= TEN_DAYS_MS
}
