/** Integer paise as Indian rupees. Billing never stores a float. */
export function formatPaise(paise: number): string {
  const sign = paise < 0 ? '−' : ''
  const formatted = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(Math.abs(paise) / 100)
  return `${sign}${formatted}`
}

export function rupeesToPaise(rupees: number): number {
  return Math.round(rupees * 100)
}
