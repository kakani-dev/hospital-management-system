import { ApiError } from '../../lib/api/client'
import type { BillListItem, DayEndAccountTotal, PatientSearchRequest, QueueEntry } from '../../lib/api/types'

/** Shortest phone the server accepts (PatientPhone.MinDigits). */
export const MIN_PHONE_DIGITS = 7
const ABHA = /^\d{2}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}$/

/**
 * One box for phone, name, MRN or ABHA. 14 digits (dashes optional) is an ABHA number; a mostly
 * numeric term with 7+ digits is a phone; anything else is a name/MRN fragment (2+ characters).
 */
export function classifySearch(raw: string): PatientSearchRequest | null {
  const term = raw.trim()
  if (ABHA.test(term)) return { abha: term }
  const digits = term.replace(/\D/g, '')
  if (/^[+\d\s()-]+$/.test(term) && digits.length >= MIN_PHONE_DIGITS) return { phone: term }
  return term.length >= 2 ? { search: term } : null
}

/** Indian notes a patient is likely to hand over. Quick buttons are derived from the due, not fixed. */
const NOTES = [50, 100, 200, 500, 2000]

/** Exact due first, then the next round amounts a cashier is likely to receive (rupees, max 4). */
export function quickTenders(duePaise: number): number[] {
  if (duePaise <= 0) return []
  const due = Math.ceil(duePaise / 100)
  const out = new Set<number>([duePaise / 100])
  for (const note of NOTES) {
    const up = Math.ceil(due / note) * note
    if (up > duePaise / 100) out.add(up)
    if (out.size >= 4) break
  }
  return [...out].sort((a, b) => a - b)
}

/** Change to hand back for cash; 0 when nothing typed or not enough. */
export function changeDue(duePaise: number, receivedPaise: number | null): number {
  return receivedPaise != null && receivedPaise > duePaise ? receivedPaise - duePaise : 0
}

/** Draft bills with money still due, oldest first, joined to today's token when there is one. */
export function waitingToPay(bills: BillListItem[], queue: QueueEntry[]) {
  return bills
    .filter((b) => b.status === 'draft' && (b.duePaise ?? 0) > 0)
    .map((b) => ({ bill: b, token: queue.find((q) => q.patientId === b.patientId && q.status !== 'cancelled')?.tokenNo ?? null }))
    .sort((a, b) => b.bill.createdOn.localeCompare(a.bill.createdOn))
}

/** Today's collection by mode (cash, UPI, card, ...), net of refunds. */
export function collectionByMode(rows: DayEndAccountTotal[]): { mode: string; netPaise: number; count: number }[] {
  const by = new Map<string, { netPaise: number; count: number }>()
  for (const r of rows) {
    const cur = by.get(r.mode) ?? { netPaise: 0, count: 0 }
    cur.netPaise += r.netPaise ?? 0
    cur.count += r.count
    by.set(r.mode, cur)
  }
  return [...by.entries()].map(([mode, v]) => ({ mode, ...v })).sort((a, b) => b.netPaise - a.netPaise)
}

/** Waiting tokens per doctor today. */
export function waitingCount(queue: QueueEntry[], practitionerId: string): number {
  return queue.filter((q) => q.practitionerId === practitionerId && q.status === 'waiting').length
}

const BRANCH_KEY = 'hms.opCounter.branch'
/** Branch remembered per user on this workstation (only an id; the server still checks access). */
export const rememberedBranch = {
  get: (userId: string | undefined) => (userId ? localStorage.getItem(`${BRANCH_KEY}.${userId}`) : null),
  set: (userId: string | undefined, branchId: string) => {
    if (userId) localStorage.setItem(`${BRANCH_KEY}.${userId}`, branchId)
  },
}

/** What the cashier sees on failure: the server's plain-language detail (e.g. "Already checked in…"), not the bare HTTP title. */
export function errorText(e: unknown): string {
  if (e instanceof ApiError) return e.problem?.detail || e.message
  return e instanceof Error ? e.message : 'Something went wrong.'
}
