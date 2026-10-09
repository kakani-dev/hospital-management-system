/**
 * Registry of API requests the user is waiting for, across retries and backoff waits (one entry
 * per logical request, not per attempt). Drives the "Waking the server…" banner: the banner only
 * needs the start time of the oldest request still pending. Never holds URLs, bodies or PHI.
 */

export interface PendingHandle {
  /** Removes the entry (always call it, in a finally). */
  end: () => void
  /** Registers what "Retry now" does for this request while it waits for a backoff (null = nothing). */
  setKick: (kick: (() => void) | null) => void
}

interface Entry {
  startedAt: number
  kick: (() => void) | null
}

const entries = new Map<number, Entry>()
const listeners = new Set<() => void>()
let nextId = 0
let oldest: number | null = null

function recompute() {
  let min: number | null = null
  for (const e of entries.values()) if (min === null || e.startedAt < min) min = e.startedAt
  if (min !== oldest) {
    oldest = min
    listeners.forEach((l) => l())
  }
}

export function beginPending(now: number = Date.now()): PendingHandle {
  const id = ++nextId
  entries.set(id, { startedAt: now, kick: null })
  recompute()
  return {
    end: () => {
      if (entries.delete(id)) recompute()
    },
    setKick: (kick) => {
      const entry = entries.get(id)
      if (entry) entry.kick = kick
    },
  }
}

/** Start time (Date.now()) of the oldest pending request, or null when nothing is pending. */
export function oldestPendingStart(): number | null {
  return oldest
}

export function subscribePending(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** "Retry now": every request waiting for a backoff tries again immediately. */
export function retryPendingNow(): number {
  let kicked = 0
  for (const e of entries.values()) {
    if (e.kick) {
      const kick = e.kick
      e.kick = null
      kick()
      kicked++
    }
  }
  return kicked
}

/** Test helper: forget everything. */
export function resetPending() {
  entries.clear()
  recompute()
}
