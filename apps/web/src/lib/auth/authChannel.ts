/**
 * Cross-tab signalling for auth events (sign-out, idle activity). Never carries tokens or PHI.
 *
 * supabase-js already broadcasts its own auth events to other tabs, but with sessionStorage each tab
 * keeps its own copy of the session, so an explicit sign-out must also tell the other tabs to drop
 * theirs. BroadcastChannel is used when available, else `storage` events on a localStorage marker key.
 */
export type AuthChannelMessage = { type: 'signed-out' } | { type: 'activity' }

export interface AuthChannel {
  post: (message: AuthChannelMessage) => void
  close: () => void
}

export const AUTH_CHANNEL_NAME = 'hms.auth.events'

function isMessage(value: unknown): value is AuthChannelMessage {
  const type = (value as { type?: unknown } | null)?.type
  return type === 'signed-out' || type === 'activity'
}

export function openAuthChannel(onMessage: (message: AuthChannelMessage) => void): AuthChannel {
  if (typeof BroadcastChannel !== 'undefined') {
    const channel = new BroadcastChannel(AUTH_CHANNEL_NAME)
    channel.onmessage = (event: MessageEvent) => {
      if (isMessage(event.data)) onMessage(event.data)
    }
    return {
      post: (message) => {
        try {
          channel.postMessage(message)
        } catch {
          /* channel already closed */
        }
      },
      close: () => channel.close(),
    }
  }
  if (typeof window === 'undefined') return { post: () => {}, close: () => {} }

  const onStorage = (event: StorageEvent) => {
    if (event.key !== AUTH_CHANNEL_NAME || !event.newValue) return
    try {
      const parsed: unknown = JSON.parse(event.newValue)
      if (isMessage(parsed)) onMessage(parsed)
    } catch {
      /* ignore malformed markers */
    }
  }
  window.addEventListener('storage', onStorage)
  return {
    post: (message) => {
      try {
        // A changing nonce makes every post a new value, so other tabs always get a storage event.
        window.localStorage.setItem(AUTH_CHANNEL_NAME, JSON.stringify({ ...message, nonce: `${Date.now()}-${Math.random()}` }))
      } catch {
        /* storage unavailable */
      }
    },
    close: () => window.removeEventListener('storage', onStorage),
  }
}
