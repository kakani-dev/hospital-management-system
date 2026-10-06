/**
 * Runtime configuration read from VITE_* build-time variables (see .env.example).
 * Everything here ships to the browser: never put secrets in VITE_* variables.
 */

/** HIPAA §164.312(a)(2)(iii) automatic logoff: default idle timeout before the session is ended. */
export const DEFAULT_IDLE_TIMEOUT_MINUTES = 15

/**
 * Parses VITE_IDLE_TIMEOUT_MINUTES. Missing, non-numeric or non-positive values fall back to the
 * default; values are capped at 12 hours so a typo cannot effectively disable auto-logoff.
 */
export function parseIdleTimeoutMinutes(raw: string | undefined | null): number {
  const value = Number(raw)
  if (raw === undefined || raw === null || String(raw).trim() === '' || !Number.isFinite(value) || value <= 0) {
    return DEFAULT_IDLE_TIMEOUT_MINUTES
  }
  return Math.min(value, 12 * 60)
}

export const idleTimeoutMinutes = parseIdleTimeoutMinutes(import.meta.env.VITE_IDLE_TIMEOUT_MINUTES)
export const idleTimeoutMs = Math.round(idleTimeoutMinutes * 60_000)
