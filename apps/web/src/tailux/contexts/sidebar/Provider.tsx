// Ported from Tailux starter src/app/contexts/sidebar/Provider.jsx (typed).
import { useCallback, useLayoutEffect, useMemo, useState, type ReactNode } from 'react'
import { useBreakpointsContext } from '../breakpoint/context'
import { SidebarContext } from './context'

export function SidebarProvider({ children }: { children: ReactNode }) {
  const { xlAndUp, lgAndDown, name } = useBreakpointsContext()
  const [isExpanded, setIsExpanded] = useState(xlAndUp)

  // Close the sidebar when the breakpoint changes to lg or below (template behaviour), adjusting
  // state during render instead of in an effect.
  const [lastName, setLastName] = useState(name)
  if (lastName !== name) {
    setLastName(name)
    if (lgAndDown) setIsExpanded(false)
  }

  useLayoutEffect(() => {
    document.body.classList.toggle('is-sidebar-open', isExpanded)
    return () => document.body.classList.remove('is-sidebar-open')
  }, [isExpanded])

  const open = useCallback(() => setIsExpanded(true), [])
  const close = useCallback(() => setIsExpanded(false), [])
  const toggle = useCallback(() => setIsExpanded((v) => !v), [])

  const value = useMemo(() => ({ isExpanded, open, close, toggle }), [isExpanded, open, close, toggle])
  return <SidebarContext value={value}>{children}</SidebarContext>
}
