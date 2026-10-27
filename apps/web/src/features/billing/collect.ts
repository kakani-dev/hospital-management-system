import { formatPaise, parseRupeesToPaise } from './money'

export type TenderMode = 'cash' | 'upi' | 'card' | 'split'

/** "ecg 2" -> { text: "ecg", quantity: 2 }. A lone number is a search, not a quantity. */
export function splitQuantity(raw: string): { text: string; quantity: number | null } {
  const trimmed = raw.trim()
  const match = /^(.*\S)\s+(?:x\s*)?(\d{1,3})$/i.exec(trimmed)
  if (!match) return { text: trimmed, quantity: null }
  const quantity = Number(match[2])
  return quantity > 0 ? { text: match[1] ?? trimmed, quantity } : { text: trimmed, quantity: null }
}

export function splitUpiHint(duePaise: number, cashRupees: string) {
  const cash = parseRupeesToPaise(cashRupees) ?? 0
  return (Math.max(duePaise - cash, 0) / 100).toFixed(2)
}

/** What the Collect button will record (never more than due; cash change is handed back). */
export function collectAmount(mode: TenderMode, duePaise: number, received: string, upi: string): number {
  const plan = planTenders(mode, duePaise, received, upi, '')
  return 'error' in plan ? duePaise : plan.totalPaise
}

/**
 * Tenders for one collection (#172). Empty amount means the full due. Cash above the due is
 * change, not money kept. UPI and card can't exceed the due. Split is cash + UPI.
 */
export function planTenders(
  mode: TenderMode,
  duePaise: number,
  received: string,
  upi: string,
  reference: string,
): { tenders: { mode: string; amountPaise: number; reference?: string }[]; totalPaise: number } | { error: string } {
  const typed = received.trim() === '' ? duePaise : parseRupeesToPaise(received)
  if (typed == null || typed < 0) return { error: 'Enter the amount in rupees.' }
  if (mode === 'split') {
    const upiPaise = upi.trim() === '' ? Math.max(duePaise - typed, 0) : parseRupeesToPaise(upi)
    if (upiPaise == null || upiPaise < 0) return { error: 'Enter the UPI amount in rupees.' }
    if (typed === 0 || upiPaise === 0) return { error: 'A split needs both a cash and a UPI amount.' }
    if (typed + upiPaise > duePaise) return { error: `Cash + UPI is more than the ${formatPaise(duePaise)} due.` }
    return { tenders: [{ mode: 'cash', amountPaise: typed }, { mode: 'upi', amountPaise: upiPaise }], totalPaise: typed + upiPaise }
  }
  if (typed === 0) return { error: 'Enter an amount above zero.' }
  if (mode !== 'cash' && typed > duePaise) return { error: `That is more than the ${formatPaise(duePaise)} due.` }
  const amountPaise = Math.min(typed, duePaise)
  const ref = reference.trim()
  return { tenders: [{ mode, amountPaise, ...(ref ? { reference: ref } : {}) }], totalPaise: amountPaise }
}
