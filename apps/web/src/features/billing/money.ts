/** Integer paise as Indian rupees. Billing never stores a float. */
export function formatPaise(paise: number): string {
  const sign = paise < 0 ? '−' : ''
  const formatted = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(Math.abs(paise) / 100)
  return `${sign}${formatted}`
}

export function rupeesToPaise(rupees: number): number {
  return Math.round(rupees * 100)
}

/** Rupees typed by a person ("1,500.50", "₹150") as integer paise. Rejects more than two decimals. */
export function parseRupeesToPaise(input: string): number | null {
  const text = input.trim().replace(/[₹,\s]/g, '')
  if (!/^\d+(\.\d{1,2})?$/.test(text)) return null
  const [whole, frac = ''] = text.split('.')
  const paise = Number(whole) * 100 + Number((frac + '00').slice(0, 2))
  return Number.isSafeInteger(paise) ? paise : null
}
