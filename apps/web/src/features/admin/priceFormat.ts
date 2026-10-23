const CATEGORY_LABEL: Record<string, string> = {
  consultation: 'Consultation',
  procedure: 'Procedure',
  lab: 'Lab',
  imaging: 'Imaging',
  consumable: 'Consumable',
  room: 'Room',
  package: 'Package',
  other: 'Other',
}

export function categoryLabel(category: string): string {
  return CATEGORY_LABEL[category] ?? category
}

/** SAC 9993 healthcare services are exempt. rateBp is basis points (1800 = 18%). */
export function formatServiceTax(rateBp: number, sac: string, isExempt: boolean): string {
  if (isExempt || rateBp === 0) return `Exempt · SAC ${sac}`
  const percent = rateBp % 100 === 0 ? String(rateBp / 100) : (rateBp / 100).toFixed(2)
  return `${percent}% GST · SAC ${sac}`
}

export function formatIsoDate(value: string | null | undefined): string {
  if (!value) return 'open'
  const day = value.slice(0, 10)
  const [y, m, d] = day.split('-').map(Number)
  if (!y || !m || !d) return day
  return new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(Date.UTC(y, m - 1, d)))
}

export function formatPricePeriod(from: string, to: string | null): string {
  return `${formatIsoDate(from)} – ${to ? formatIsoDate(to) : 'open'}`
}
