import type { Capability } from '../../lib/permissions'

/**
 * Reception keyboard shortcuts. Alt+letter combinations use `KeyboardEvent.code` (layout- and
 * macOS-Option-proof) and work even while typing in a field; "/" and "?" only outside fields.
 */
export interface Shortcut {
  id: 'search' | 'register' | 'check-in' | 'walk-in' | 'queue' | 'book' | 'palette' | 'desk' | 'help'
  /** Human label, also used for aria-keyshortcuts. */
  keys: string
  description: string
  /** Hidden (and inactive) when the role lacks this capability. */
  capability?: Capability
}

export const SHORTCUTS: Shortcut[] = [
  { id: 'palette', keys: 'Ctrl+K', description: 'Search patients and actions (opens on the current page)' },
  { id: 'search', keys: '/', description: 'Find a patient (focus the patient search)' },
  { id: 'register', keys: 'Alt+N', description: 'Register a new patient (from a patient picker: pre-filled with what you typed)', capability: 'patients.write' },
  { id: 'check-in', keys: 'Alt+C', description: 'Reception check-in', capability: 'queue.checkIn' },
  { id: 'walk-in', keys: 'Alt+W', description: 'Walk-in: focus the walk-in patient search', capability: 'queue.checkIn' },
  { id: 'queue', keys: 'Alt+Q', description: 'OPD queue board', capability: 'queue.view' },
  { id: 'book', keys: 'Alt+K', description: 'Book an appointment', capability: 'appointments.book' },
  { id: 'desk', keys: 'Alt+D', description: 'Hospital desk: invite staff and manage branches', capability: 'admin.members' },
  { id: 'help', keys: '?', description: 'Show this list' },
]

export const ALT_CODES: Record<string, Shortcut['id']> = {
  KeyN: 'register',
  KeyC: 'check-in',
  KeyW: 'walk-in',
  KeyQ: 'queue',
  KeyK: 'book',
  KeyD: 'desk',
}

/** True when the key press is text entry (inputs, textareas, selects, contenteditable). */
export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  const tag = target.tagName
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true
  if (tag !== 'INPUT') return false
  const type = (target as HTMLInputElement).type
  return !['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'color', 'range'].includes(type)
}

const visible = (selector: string) =>
  [...document.querySelectorAll<HTMLElement>(selector)].find((e) => !e.closest('[hidden], .hidden') && !(e as HTMLInputElement).disabled)

/**
 * Focuses the first visible element matching `selector`, waiting for it to render (lazy routes,
 * data loading) up to `timeoutMs`. With a `fallback`, that is focused as soon as it exists and is
 * upgraded to `selector` when it appears, unless the user has moved focus meanwhile.
 * Returns a cancel function.
 */
export function focusWhenReady(selector: string, { fallback, timeoutMs = 3_000 }: { fallback?: string; timeoutMs?: number } = {}): () => void {
  const started = Date.now()
  let timer: ReturnType<typeof setTimeout> | undefined
  let fallbackEl: HTMLElement | null = null
  const tryFocus = () => {
    const el = visible(selector)
    if (el) {
      const userMoved = fallbackEl && document.activeElement !== fallbackEl && document.activeElement !== document.body
      if (!userMoved) {
        el.focus()
        if (el instanceof HTMLInputElement) el.select?.()
      }
      return
    }
    if (fallback && !fallbackEl) {
      fallbackEl = visible(fallback) ?? null
      fallbackEl?.focus()
    }
    if (Date.now() - started < timeoutMs) timer = setTimeout(tryFocus, 50)
  }
  tryFocus()
  return () => clearTimeout(timer)
}
