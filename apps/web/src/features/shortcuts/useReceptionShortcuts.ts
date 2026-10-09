import { useEffect, useRef } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { can } from '../../lib/permissions'
import { ALT_CODES, focusWhenReady, isTypingTarget, SHORTCUTS, type Shortcut } from './shortcuts'

const SEARCH = '[data-shortcut="patient-search"]'
const WALK_IN = '[data-shortcut="walk-in"]'
const HEADING = 'main h1'
const BOOKING = 'form[aria-label="Book appointment"] select'

/** Global keyboard shortcuts for the signed-in shell (see shortcuts.ts). */
export function useReceptionShortcuts({ roles, onHelp }: { roles: string[]; onHelp: () => void }) {
  const navigate = useNavigate()
  const location = useLocation()
  const latest = useRef({ roles, onHelp, navigate, pathname: location.pathname })
  useEffect(() => {
    latest.current = { roles, onHelp, navigate, pathname: location.pathname }
  })

  useEffect(() => {
    let cancelFocus: (() => void) | null = null
    const allowed = (id: Shortcut['id']) => {
      const s = SHORTCUTS.find((x) => x.id === id)!
      return !s.capability || can(latest.current.roles, s.capability)
    }
    const go = (path: string, focusSelector: string, state?: unknown) => {
      cancelFocus?.()
      if (latest.current.pathname !== path || state) latest.current.navigate(path, state ? { state } : undefined)
      cancelFocus = focusWhenReady(focusSelector)
    }
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey) return
      if (e.altKey && !e.shiftKey) {
        const id = ALT_CODES[e.code]
        if (!id || !allowed(id)) return
        e.preventDefault()
        if (id === 'register') go('/patients/new', 'form[aria-label="Register patient"] input[name="mrn"]')
        else if (id === 'check-in') go('/reception/check-in', `[data-shortcut="checkin-list"] button:not([disabled]), ${HEADING}`)
        else if (id === 'walk-in') go('/reception/check-in', WALK_IN)
        else if (id === 'queue') go('/queue', HEADING)
        else if (id === 'book') {
          const open = document.querySelector<HTMLButtonElement>('[data-shortcut="open-booking"]')
          if (open && latest.current.pathname === '/appointments') {
            open.click()
            cancelFocus?.()
            cancelFocus = focusWhenReady(BOOKING)
          } else go('/appointments', BOOKING, { openBooking: true })
        }
        return
      }
      if (e.altKey || isTypingTarget(e.target)) return
      if (e.key === '/') {
        e.preventDefault()
        if (document.querySelector(SEARCH)) {
          cancelFocus?.()
          cancelFocus = focusWhenReady(SEARCH)
        } else go('/patients', SEARCH)
      } else if (e.key === '?') {
        e.preventDefault()
        latest.current.onHelp()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      cancelFocus?.()
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [])
}
