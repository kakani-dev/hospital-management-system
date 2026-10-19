/** Legacy aliases some browsers still report; the API stores the canonical id (identity.canonical_time_zone). */
const CANONICAL: Record<string, string> = {
  'Asia/Calcutta': 'Asia/Kolkata',
  'Asia/Saigon': 'Asia/Ho_Chi_Minh',
  'Asia/Katmandu': 'Asia/Kathmandu',
  'Asia/Rangoon': 'Asia/Yangon',
  'Asia/Dacca': 'Asia/Dhaka',
  'Etc/UTC': 'UTC',
}

export const canonicalZone = (zone: string) => CANONICAL[zone] ?? zone

/** The workstation's zone as a SUGGESTION only (the hospital's zone is what the user confirms). */
export function suggestedZone(): string {
  try {
    return canonicalZone(Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC')
  } catch {
    return 'UTC'
  }
}

/** IANA ids for the zone picker suggestions (the server validates against pg_timezone_names). */
export function ianaZones(): string[] {
  const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] }
  const list = intl.supportedValuesOf?.('timeZone') ?? ['Asia/Kolkata', 'Asia/Dubai', 'Europe/London', 'America/New_York', 'UTC']
  return [...new Set(list.map(canonicalZone).concat('UTC'))].sort()
}

/** Lower-case hyphenated code from a hospital name (the operator can edit it). */
export function codeFromName(name: string): string {
  const slug = name
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/g, '')
  return slug.length >= 2 ? slug : `hospital-${slug}`.replace(/-+$/g, '')
}
