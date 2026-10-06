import { useEffect, useRef } from 'react'
import { openAuthChannel } from '../../lib/auth/authChannel'

/** User input that counts as activity (any of them resets the idle timer). */
export const ACTIVITY_EVENTS = ['pointerdown', 'pointermove', 'keydown', 'wheel', 'touchstart', 'scroll'] as const

/** Activity is shared with other HMS tabs at most this often, so a busy tab keeps idle ones alive. */
const BROADCAST_INTERVAL_MS = 5_000

export interface IdleTimeoutOptions {
  enabled: boolean
  timeoutMs: number
  onTimeout: () => void
}

/**
 * Automatic logoff (HIPAA §164.312(a)(2)(iii)): calls `onTimeout` once no activity has been seen —
 * in this tab or any other HMS tab — for `timeoutMs`. The deadline is re-checked when the tab
 * becomes visible again, because browsers throttle timers in background tabs and during sleep.
 */
export function useIdleTimeout({ enabled, timeoutMs, onTimeout }: IdleTimeoutOptions) {
  const onTimeoutRef = useRef(onTimeout)
  useEffect(() => {
    onTimeoutRef.current = onTimeout
  }, [onTimeout])

  useEffect(() => {
    if (!enabled || !(timeoutMs > 0)) return
    let lastActivity = Date.now()
    let lastBroadcast = 0
    let fired = false
    let timer: ReturnType<typeof setTimeout> | undefined

    const check = () => {
      if (fired) return
      const idleFor = Date.now() - lastActivity
      if (idleFor >= timeoutMs) {
        fired = true
        clearTimeout(timer)
        onTimeoutRef.current()
        return
      }
      clearTimeout(timer)
      timer = setTimeout(check, timeoutMs - idleFor)
    }

    const channel = openAuthChannel((message) => {
      if (message.type === 'activity') lastActivity = Date.now()
    })

    const onActivity = () => {
      if (fired) return
      const now = Date.now()
      lastActivity = now
      if (now - lastBroadcast >= BROADCAST_INTERVAL_MS) {
        lastBroadcast = now
        channel.post({ type: 'activity' })
      }
    }
    const onVisibility = () => {
      if (document.visibilityState === 'visible') check()
    }

    for (const type of ACTIVITY_EVENTS) window.addEventListener(type, onActivity, { passive: true, capture: true })
    document.addEventListener('visibilitychange', onVisibility)
    timer = setTimeout(check, timeoutMs)

    return () => {
      clearTimeout(timer)
      for (const type of ACTIVITY_EVENTS) window.removeEventListener(type, onActivity, { capture: true })
      document.removeEventListener('visibilitychange', onVisibility)
      channel.close()
    }
  }, [enabled, timeoutMs])
}
