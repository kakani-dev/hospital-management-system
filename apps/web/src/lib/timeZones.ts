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

/** The zone a new hospital / branch starts with when nothing better is known. */
export const DEFAULT_ZONE = 'Asia/Kolkata'

/**
 * Static fallback for browsers without Intl.supportedValuesOf('timeZone') (older Safari / WebViews):
 * one or more canonical IANA ids per region. The server still validates against pg_timezone_names.
 */
export const FALLBACK_ZONES: readonly string[] = [
  'Africa/Abidjan', 'Africa/Accra', 'Africa/Addis_Ababa', 'Africa/Algiers', 'Africa/Cairo', 'Africa/Casablanca', 'Africa/Dar_es_Salaam',
  'Africa/Johannesburg', 'Africa/Khartoum', 'Africa/Kinshasa', 'Africa/Lagos', 'Africa/Nairobi', 'Africa/Tripoli', 'Africa/Tunis',
  'America/Anchorage', 'America/Argentina/Buenos_Aires', 'America/Bogota', 'America/Caracas', 'America/Chicago', 'America/Denver',
  'America/Edmonton', 'America/Halifax', 'America/Havana', 'America/Lima', 'America/Los_Angeles', 'America/Mexico_City',
  'America/Montevideo', 'America/New_York', 'America/Panama', 'America/Phoenix', 'America/Puerto_Rico', 'America/Santiago',
  'America/Sao_Paulo', 'America/St_Johns', 'America/Toronto', 'America/Vancouver', 'America/Winnipeg',
  'Asia/Almaty', 'Asia/Amman', 'Asia/Baghdad', 'Asia/Baku', 'Asia/Bangkok', 'Asia/Beirut', 'Asia/Colombo', 'Asia/Damascus',
  'Asia/Dhaka', 'Asia/Dubai', 'Asia/Ho_Chi_Minh', 'Asia/Hong_Kong', 'Asia/Jakarta', 'Asia/Jerusalem', 'Asia/Kabul', 'Asia/Karachi',
  'Asia/Kathmandu', 'Asia/Kolkata', 'Asia/Kuala_Lumpur', 'Asia/Kuwait', 'Asia/Manila', 'Asia/Muscat', 'Asia/Qatar', 'Asia/Riyadh',
  'Asia/Seoul', 'Asia/Shanghai', 'Asia/Singapore', 'Asia/Taipei', 'Asia/Tashkent', 'Asia/Tbilisi', 'Asia/Tehran', 'Asia/Thimphu',
  'Asia/Tokyo', 'Asia/Ulaanbaatar', 'Asia/Vladivostok', 'Asia/Yangon', 'Asia/Yekaterinburg', 'Asia/Yerevan',
  'Atlantic/Azores', 'Atlantic/Reykjavik', 'Australia/Adelaide', 'Australia/Brisbane', 'Australia/Darwin', 'Australia/Melbourne',
  'Australia/Perth', 'Australia/Sydney', 'Europe/Amsterdam', 'Europe/Athens', 'Europe/Belgrade', 'Europe/Berlin', 'Europe/Brussels',
  'Europe/Bucharest', 'Europe/Budapest', 'Europe/Dublin', 'Europe/Helsinki', 'Europe/Istanbul', 'Europe/Kyiv', 'Europe/Lisbon',
  'Europe/London', 'Europe/Madrid', 'Europe/Moscow', 'Europe/Oslo', 'Europe/Paris', 'Europe/Prague', 'Europe/Rome', 'Europe/Stockholm',
  'Europe/Vienna', 'Europe/Warsaw', 'Europe/Zurich', 'Indian/Maldives', 'Indian/Mauritius', 'Pacific/Auckland', 'Pacific/Fiji',
  'Pacific/Guam', 'Pacific/Honolulu', 'Pacific/Port_Moresby', 'UTC',
]

let cachedZones: string[] | null = null

/** IANA ids for the zone picker (the server validates against pg_timezone_names). */
export function ianaZones(): string[] {
  if (cachedZones) return cachedZones
  let list: readonly string[] = []
  try {
    const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] }
    list = intl.supportedValuesOf?.('timeZone') ?? []
  } catch {
    list = []
  }
  if (list.length === 0) list = FALLBACK_ZONES
  cachedZones = [...new Set(list.map(canonicalZone).concat('UTC'))].sort()
  return cachedZones
}

/** Test hook: forget the cached list (after stubbing Intl). */
export function resetZoneCache() {
  cachedZones = null
}

const fold = (s: string) => s.toLowerCase().replace(/[\s_]+/g, '')

/** The listed zone the text names exactly (case, spaces vs underscores and legacy aliases ignored), else null. */
export function matchZone(text: string, zones: readonly string[] = ianaZones()): string | null {
  const t = text.trim()
  if (!t) return null
  const canonical = canonicalZone(t)
  if (zones.includes(canonical)) return canonical
  const f = fold(canonical)
  return zones.find((z) => fold(z) === f) ?? null
}

/** "UTC+05:30" for a zone at `at` (DST-aware); "" when the runtime cannot tell. */
export function zoneOffsetLabel(zone: string, at: Date = new Date()): string {
  try {
    const part = new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'longOffset' })
      .formatToParts(at)
      .find((p) => p.type === 'timeZoneName')?.value
    if (!part) return ''
    return part === 'GMT' ? 'UTC+00:00' : part.replace('GMT', 'UTC')
  } catch {
    return ''
  }
}

/** Zones whose id or offset contains the query ("kolk", "new york", "+05:30"); all zones for an empty query. */
export function filterZones(query: string, zones: readonly string[] = ianaZones(), offsets?: ReadonlyMap<string, string>): string[] {
  const q = fold(query)
  if (!q) return [...zones]
  return zones.filter((z) => fold(z).includes(q) || (offsets?.get(z) ?? '').toLowerCase().replace(/\s+/g, '').includes(q))
}

/** The workstation's zone if the picker lists it, else Asia/Kolkata (the user still confirms the hospital's zone). */
export function defaultZone(zones: readonly string[] = ianaZones()): string {
  try {
    const browser = Intl.DateTimeFormat().resolvedOptions().timeZone
    return (browser && matchZone(browser, zones)) || DEFAULT_ZONE
  } catch {
    return DEFAULT_ZONE
  }
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
