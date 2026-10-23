import { parseRupeesToPaise } from '../billing/money'

export const SERVICE_CATEGORIES = ['consultation', 'procedure', 'lab', 'imaging', 'consumable', 'room', 'package', 'other'] as const
export type ServiceCategory = (typeof SERVICE_CATEGORIES)[number]

export const PRICE_CSV_TEMPLATE = `code,name,category,sac,rupees,effective_from,effective_to,branch_code
DRESS,Wound dressing,procedure,9993,150,2026-04-01,,
CERT,"Medical certificate, fitness",other,9993,200,2026-04-01,,main
`

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

export interface ParsedPriceRow {
  line: number
  code: string
  name: string
  category: string
  sac: string
  rupees: string
  unitPricePaise: number | null
  effectiveFrom: string
  effectiveTo: string
  branchCode: string
  error: string | null
}

export interface ParsedPriceCsv {
  fileError: string | null
  rows: ParsedPriceRow[]
}

/** Split one CSV line, keeping commas that sit inside quotes. */
export function splitCsvLine(line: string): string[] {
  const out: string[] = []
  let cur = ''
  let quoted = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (quoted) {
      if (ch === '"') {
        if (line[i + 1] === '"') {
          cur += '"'
          i++
        } else quoted = false
      } else cur += ch
    } else if (ch === '"') quoted = true
    else if (ch === ',') {
      out.push(cur)
      cur = ''
    } else cur += ch
  }
  out.push(cur)
  return out.map((cell) => cell.trim())
}

function isCategory(value: string): value is ServiceCategory {
  return (SERVICE_CATEGORIES as readonly string[]).includes(value)
}

/**
 * Hospital CSV → rows the billing import can preview.
 * Amounts become paise here. Branch codes stay text until the screen maps them to ids.
 */
export function parsePriceCsv(text: string): ParsedPriceCsv {
  const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/)
  const headerIndex = lines.findIndex((line) => line.trim().length > 0)
  if (headerIndex < 0) return { fileError: 'The file is empty.', rows: [] }
  const header = splitCsvLine(lines[headerIndex]!).map((cell) => cell.toLowerCase())
  const col = (name: string) => header.indexOf(name)
  if (col('code') < 0 || col('rupees') < 0 || col('effective_from') < 0) {
    return { fileError: 'The header must include code, rupees and effective_from.', rows: [] }
  }

  const rows: ParsedPriceRow[] = []
  for (let i = headerIndex + 1; i < lines.length; i++) {
    if (lines[i]!.trim().length === 0) continue
    const cells = splitCsvLine(lines[i]!)
    const at = (name: string) => {
      const index = col(name)
      return index < 0 ? '' : (cells[index] ?? '')
    }
    const code = at('code')
    const name = at('name')
    const categoryRaw = at('category').toLowerCase()
    const category = categoryRaw || 'other'
    const sac = at('sac') || '9993'
    const rupees = at('rupees')
    const effectiveFrom = at('effective_from')
    const effectiveTo = at('effective_to')
    const branchCode = at('branch_code')
    const unitPricePaise = parseRupeesToPaise(rupees)
    let error: string | null = null
    if (!code) error = 'Code is required.'
    else if (code.length > 40) error = 'Code is longer than 40 characters.'
    else if (!isCategory(category)) error = 'Category is not recognised.'
    else if (unitPricePaise === null) error = 'Amount must be rupees with at most two decimals.'
    else if (!ISO_DATE.test(effectiveFrom)) error = 'Effective from must be YYYY-MM-DD.'
    else if (effectiveTo && !ISO_DATE.test(effectiveTo)) error = 'Effective to must be YYYY-MM-DD.'
    else if (effectiveTo && effectiveTo <= effectiveFrom) error = 'Effective to must be after the start.'
    else if (name.length > 160) error = 'Name is longer than 160 characters.'
    rows.push({ line: i + 1, code, name, category, sac, rupees, unitPricePaise, effectiveFrom, effectiveTo, branchCode, error })
  }
  if (rows.length === 0) return { fileError: 'The file has no data rows.', rows: [] }
  return { fileError: null, rows }
}
