/**
 * Calendar date (YYYY-MM-DD) of `now` in `timeZone` — by default the browser's own zone, i.e. the
 * branch workstation's local time. Never derive "today" from toISOString(): that is the UTC date,
 * which in IST lags the local date between 00:00 and 05:30 (newborns would be rejected at night).
 */
export function localToday(now: Date = new Date(), timeZone?: string): string {
  if (timeZone) {
    // en-CA formats as YYYY-MM-DD.
    return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
  }
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/

function parseDate(date: string): Date {
  const m = DATE_RE.exec(date)
  if (!m) throw new Error(`Invalid calendar date: ${date}`)
  // Pure calendar arithmetic in UTC: no DST or local-zone shifts.
  return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])))
}

const iso = (d: Date) => d.toISOString().slice(0, 10)

export function isCalendarDate(value: string): boolean {
  if (!DATE_RE.test(value)) return false
  return iso(parseDate(value)) === value
}

/** YYYY-MM-DD shifted by `days` calendar days. */
export function addDays(date: string, days: number): string {
  const d = parseDate(date)
  d.setUTCDate(d.getUTCDate() + days)
  return iso(d)
}

/** Monday of the ISO week containing `date`. */
export function startOfWeek(date: string): string {
  const day = parseDate(date).getUTCDay() // 0 = Sunday
  return addDays(date, -((day + 6) % 7))
}

/** The seven dates (Mon..Sun) of the week containing `date`. */
export function weekDates(date: string): string[] {
  const monday = startOfWeek(date)
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i))
}

/** "Mon 12 Oct" style label for a calendar date (the date itself, independent of any zone). */
export function formatDayLabel(date: string, locale = 'en-IN'): string {
  return new Intl.DateTimeFormat(locale, { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' }).format(parseDate(date))
}

/** Calendar date of an instant in a time zone (e.g. the branch's), default the browser's. */
export function dateInZone(instant: string | Date, timeZone?: string): string {
  return localToday(typeof instant === 'string' ? new Date(instant) : instant, timeZone)
}

/** 24-hour HH:mm of an instant in a time zone (e.g. the branch's). */
export function formatTime(instant: string | Date, timeZone?: string, locale = 'en-GB'): string {
  return new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone }).format(
    typeof instant === 'string' ? new Date(instant) : instant,
  )
}

/**
 * Latest calendar date anywhere (UTC+14). Only a permissive upper bound ("not in the future") while
 * no branch or hospital zone is known; the API re-checks in the branch zone. Never a display zone.
 */
export function latestToday(now: Date = new Date()): string {
  return localToday(now, 'Pacific/Kiritimati')
}

/** The browser's IANA zone. Not used for branch dates or times (branch → hospital zone only). */
export function browserTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone
}

/** Offset (ms) of `timeZone` from UTC at `instant`. */
function zoneOffsetMs(instant: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(instant))
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value)
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'))
  return asUtc - Math.floor(instant / 1000) * 1000
}

/**
 * The instant (UTC ISO string) of a branch-local wall-clock time, e.g. midnight of a calendar day
 * in Asia/Kolkata. DST-safe: the offset is re-evaluated at the candidate instant.
 */
export function zonedTimeToInstant(date: string, time: string, timeZone: string): string {
  const d = parseDate(date)
  const [hh = 0, mm = 0] = time.split(':').map(Number)
  const wall = d.getTime() + (hh * 60 + mm) * 60_000
  let instant = wall - zoneOffsetMs(wall, timeZone)
  instant = wall - zoneOffsetMs(instant, timeZone)
  return new Date(instant).toISOString()
}

/** ISO weekday of a calendar date: 1 = Monday … 7 = Sunday. */
export function isoWeekday(date: string): number {
  const day = parseDate(date).getUTCDay()
  return day === 0 ? 7 : day
}
