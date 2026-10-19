// Ported from Tailux starter src/app/contexts/breakpoint/Provider.jsx (typed).
import { useEffect, useState, type ReactNode } from 'react'
import { breakpoints } from '../../configs/breakpoints.config'
import { BreakpointsContext, type BreakpointState } from './context'

export function getBreakpoint(width = window.innerWidth): BreakpointState {
  let name = ''
  const xs = width < breakpoints.SM
  const sm = width < breakpoints.MD && !xs
  const md = width < breakpoints.LG && !(sm || xs)
  const lg = width < breakpoints.XL && !(md || sm || xs)
  const xl = width < breakpoints['2XL'] && !(lg || md || sm || xs)
  const the2xl = width >= breakpoints['2XL']

  if (xs) name = 'xs'
  if (sm) name = 'sm'
  if (md) name = 'md'
  if (lg) name = 'lg'
  if (xl) name = 'xl'
  if (the2xl) name = '2xl'

  return {
    name,
    isXs: xs,
    isSm: sm,
    isMd: md,
    isLg: lg,
    isXl: xl,
    is2xl: the2xl,
    smAndDown: (xs || sm) && !(md || lg || xl || the2xl),
    smAndUp: !xs && (sm || md || lg || xl || the2xl),
    mdAndDown: (xs || sm || md) && !(lg || xl || the2xl),
    mdAndUp: !(xs || sm) && (md || lg || xl || the2xl),
    lgAndDown: (xs || sm || md || lg) && !(xl || the2xl),
    lgAndUp: !(xs || sm || md) && (lg || xl || the2xl),
    xlAndDown: (xs || sm || md || lg || xl) && !the2xl,
    xlAndUp: !(xs || sm || md || lg) && (xl || the2xl),
  }
}

export function BreakpointProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<BreakpointState>(() => getBreakpoint())

  useEffect(() => {
    const update = () => {
      const current = getBreakpoint()
      setState((prev) => (prev.name === current.name ? prev : current))
    }
    // The template observes <html> with a ResizeObserver; a resize listener is equivalent here and
    // also works in jsdom.
    window.addEventListener('resize', update)
    return () => window.removeEventListener('resize', update)
  }, [])

  return <BreakpointsContext value={state}>{children}</BreakpointsContext>
}
