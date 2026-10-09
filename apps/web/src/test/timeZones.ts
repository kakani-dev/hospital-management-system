import { vi } from 'vitest'

/** 2026-10-06T19:00:00Z = 2026-10-07 00:30 in India but still 2026-10-06 15:00 in New York. */
export const AFTER_IST_MIDNIGHT = new Date('2026-10-06T19:00:00Z')

// Node re-reads process.env.TZ at runtime, which lets a test pretend the workstation is elsewhere.
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env
const originalTz = env.TZ

/** Workstation zone + frozen Date (timers stay real so user-event and React Query keep working). */
export function workstationAt(timeZone: string, now: Date = AFTER_IST_MIDNIGHT) {
  env.TZ = timeZone
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(now)
}

export function restoreWorkstation() {
  vi.useRealTimers()
  if (originalTz === undefined) delete env.TZ
  else env.TZ = originalTz
}
