import { useEffect, useState, useSyncExternalStore } from 'react'
import { resilience } from '../config'
import { oldestPendingStart, subscribePending } from './pending'

export type WakingPhase = 'idle' | 'waking' | 'still'

/**
 * 'waking' once the oldest pending API request (retries included) has waited `afterMs`,
 * 'still' after `stillAfterMs`, back to 'idle' as soon as nothing is pending.
 */
export function useWakingPhase({
  afterMs = resilience.wakingBannerAfterMs,
  stillAfterMs = resilience.wakingStillAfterMs,
}: { afterMs?: number; stillAfterMs?: number } = {}): WakingPhase {
  const start = useSyncExternalStore(subscribePending, oldestPendingStart, oldestPendingStart)
  // Phase reached for a given start time; only ever set from timer callbacks.
  const [reached, setReached] = useState<{ start: number; phase: WakingPhase } | null>(null)

  useEffect(() => {
    if (start === null) return
    const elapsed = Date.now() - start
    const timers = [
      setTimeout(() => setReached({ start, phase: 'waking' }), Math.max(0, afterMs - elapsed)),
      setTimeout(() => setReached({ start, phase: 'still' }), Math.max(0, stillAfterMs - elapsed)),
    ]
    return () => timers.forEach(clearTimeout)
  }, [start, afterMs, stillAfterMs])

  return start !== null && reached?.start === start ? reached.phase : 'idle'
}
