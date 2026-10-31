/**
 * GS1 barcode parsing for medicine packs (DataMatrix, GS1 QR, GS1-128 and plain EAN/UPC).
 * Handles what USB keyboard-wedge scanners and camera decoders actually send:
 * - an optional AIM symbology prefix (]d2 DataMatrix, ]Q3 QR, ]C1 GS1-128, ]e0 DataBar, ]E0 EAN)
 * - FNC1 as the ASCII GS character (0x1D), or the same with the separator dropped (variable field runs to the end)
 * - the human-readable form with brackets: (01)08901234567892(17)271231(10)AB12
 * - a bare EAN-13 / UPC-A / GTIN-14 (no application identifiers)
 */
export interface Gs1Scan {
  gtin?: string
  batch?: string
  /** ISO date (yyyy-mm-dd); a "00" day means the last day of that month (GS1 rule). */
  expiry?: string
  serial?: string
  /** Set when the scan is not usable; the text is safe to show to the user. */
  error?: string
}

const GS = '\u001d'
/** Fixed-length AIs we read or must step over (value length after the AI). */
const FIXED: Record<string, number> = { '00': 18, '01': 14, '02': 14, '11': 6, '12': 6, '13': 6, '15': 6, '16': 6, '17': 6 }
/** Variable-length AIs (max length) that end at GS or the end of the data. */
const VARIABLE: Record<string, number> = { '10': 20, '21': 20, '22': 20, '240': 30, '241': 30, '30': 8, '37': 8, '91': 90, '92': 90, '93': 90, '94': 90, '95': 90, '96': 90, '97': 90, '98': 90, '99': 90, '710': 20, '711': 20, '712': 20, '713': 20, '714': 20 }

/** Mod-10 check digit used by every GTIN length. */
export function gtinValid(digits: string): boolean {
  if (!/^\d{8}$|^\d{12,14}$/.test(digits)) return false
  const body = digits.slice(0, -1)
  let sum = 0
  for (let i = 0; i < body.length; i++) sum += Number(body[body.length - 1 - i]) * (i % 2 === 0 ? 3 : 1)
  return (10 - (sum % 10)) % 10 === Number(digits[digits.length - 1])
}

/** YYMMDD to ISO with the GS1 sliding century window (−49 … +50 years from `now`). */
export function gs1Date(yymmdd: string, now: Date = new Date()): string | null {
  if (!/^\d{6}$/.test(yymmdd)) return null
  const yy = Number(yymmdd.slice(0, 2)), mm = Number(yymmdd.slice(2, 4)), dd = Number(yymmdd.slice(4, 6))
  if (mm < 1 || mm > 12) return null
  const cur = now.getFullYear()
  let year = Math.floor(cur / 100) * 100 + yy
  if (year - cur > 50) year -= 100
  else if (cur - year > 49) year += 100
  const last = new Date(Date.UTC(year, mm, 0)).getUTCDate()
  const day = dd === 0 ? last : dd
  if (day > last) return null
  return `${year}-${String(mm).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

function aiAt(data: string, i: number): string | null {
  for (const len of [2, 3, 4]) {
    const ai = data.slice(i, i + len)
    if (ai in FIXED || ai in VARIABLE) return ai
  }
  return null
}

export function parseGs1(raw: string, now: Date = new Date()): Gs1Scan {
  let data = raw.replace(/[\r\n]+$/g, '').trim()
  if (!data) return { error: 'Nothing was scanned.' }
  data = data.replace(/^\][A-Za-z]\d/, '') // AIM symbology identifier
  while (data.startsWith('\u001d')) data = data.slice(1)

  // Human-readable form: (01)...(17)...
  if (data.startsWith('(')) {
    const parts = [...data.matchAll(/\((\d{2,4})\)([^(]*)/g)]
    if (parts.length === 0) return { error: 'This code is not a GS1 medicine barcode.' }
    data = parts.map(([, ai, v]) => ai + (v ?? '').trim() + (ai! in VARIABLE ? GS : '')).join('')
  }

  // Plain retail barcode: EAN-8/UPC-A/EAN-13/GTIN-14.
  if (/^\d{8}$|^\d{12,13}$/.test(data) || (/^\d{14}$/.test(data) && !data.startsWith('01'))) {
    return gtinValid(data) ? { gtin: data.padStart(14, '0') } : { error: 'The barcode check digit is wrong. Scan again.' }
  }

  const out: Gs1Scan = {}
  let i = 0
  while (i < data.length) {
    if (data[i] === GS) { i++; continue }
    const ai = aiAt(data, i)
    if (!ai) return { ...out, error: out.gtin ? undefined : 'This code is not a GS1 medicine barcode.' }
    i += ai.length
    let value: string
    if (ai in FIXED) {
      value = data.slice(i, i + FIXED[ai]!)
      if (value.length !== FIXED[ai]) return { ...out, error: 'The barcode is cut short. Scan again.' }
      i += FIXED[ai]!
    } else {
      const end = data.indexOf(GS, i)
      const stop = end === -1 ? data.length : end
      value = data.slice(i, Math.min(stop, i + VARIABLE[ai]!))
      i = stop
    }
    if (ai === '01') {
      if (!gtinValid(value)) return { error: 'The barcode check digit is wrong. Scan again.' }
      out.gtin = value
    } else if (ai === '17') {
      const d = gs1Date(value, now)
      if (!d) return { ...out, error: 'The expiry date in the barcode is not valid.' }
      out.expiry = d
    } else if (ai === '10') out.batch = value
    else if (ai === '21') out.serial = value
  }
  if (!out.gtin) return { ...out, error: 'No product code (GTIN) in this barcode.' }
  return out
}
