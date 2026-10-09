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

// ---------------------------------------------------------------------------------------------
// Resilience on the free host (cold starts of the edge and the services). The defaults follow the
// CTO's contract (9 Oct 2026): the edge proxy times out at 30 s and answers a cold or unreachable
// service with 503 `service_unavailable` + `Retry-After: 5`. Nothing has been measured yet, so
// every number here is overridable at build time (see .env.example).
// ---------------------------------------------------------------------------------------------

/**
 * Parses a positive integer from a VITE_* string. Missing, non-numeric, non-finite or below `min`
 * falls back to `fallback`; values above `max` are capped.
 */
export function parseIntSetting(raw: string | undefined | null, fallback: number, { min = 0, max = Number.MAX_SAFE_INTEGER }: { min?: number; max?: number } = {}): number {
  if (raw === undefined || raw === null || String(raw).trim() === '') return fallback
  const value = Number(raw)
  if (!Number.isFinite(value) || value < min) return fallback
  return Math.min(Math.round(value), max)
}

export interface ResilienceConfig {
  /** Client timeout for GETs (ms). A bit above the edge's 30 s proxy timeout. */
  getTimeoutMs: number
  /** Client timeout for writes (POST/PATCH/PUT/DELETE), which are never auto-retried (ms). */
  writeTimeoutMs: number
  /** Automatic retries for a GET after the first attempt (0 disables them). */
  retryCount: number
  /** First backoff delay (ms); later delays grow by `retryFactor`, with ±25 % jitter. */
  retryBaseDelayMs: number
  retryFactor: number
  /** Cap for any single wait, including a server's Retry-After (ms). */
  retryMaxDelayMs: number
  /** "Waking the server…" banner appears after a request has been pending this long (ms). */
  wakingBannerAfterMs: number
  /** The banner switches to "Still waking… Retry now" after this long (ms). */
  wakingStillAfterMs: number
}

type Env = Partial<Record<string, string | undefined>>

export function resilienceConfigFrom(env: Env): ResilienceConfig {
  const wakingBannerAfterMs = parseIntSetting(env.VITE_WAKING_BANNER_AFTER_MS, 4_000, { min: 0, max: 600_000 })
  return {
    getTimeoutMs: parseIntSetting(env.VITE_API_GET_TIMEOUT_MS, 40_000, { min: 1_000, max: 300_000 }),
    writeTimeoutMs: parseIntSetting(env.VITE_API_WRITE_TIMEOUT_MS, 40_000, { min: 1_000, max: 300_000 }),
    retryCount: parseIntSetting(env.VITE_API_RETRY_COUNT, 3, { min: 0, max: 10 }),
    retryBaseDelayMs: parseIntSetting(env.VITE_API_RETRY_BASE_DELAY_MS, 1_000, { min: 0, max: 60_000 }),
    retryFactor: parseIntSetting(env.VITE_API_RETRY_FACTOR, 3, { min: 1, max: 10 }),
    retryMaxDelayMs: parseIntSetting(env.VITE_API_RETRY_MAX_DELAY_MS, 30_000, { min: 0, max: 300_000 }),
    wakingBannerAfterMs,
    wakingStillAfterMs: Math.max(parseIntSetting(env.VITE_WAKING_STILL_AFTER_MS, 60_000, { min: 0, max: 3_600_000 }), wakingBannerAfterMs),
  }
}

export const resilience: ResilienceConfig = resilienceConfigFrom(import.meta.env as Env)
