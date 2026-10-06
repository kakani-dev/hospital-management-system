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
