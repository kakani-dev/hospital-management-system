import { createContext, useContext } from 'react'

export interface BreakpointState {
  name: string
  isXs: boolean
  isSm: boolean
  isMd: boolean
  isLg: boolean
  isXl: boolean
  is2xl: boolean
  smAndDown: boolean
  smAndUp: boolean
  mdAndDown: boolean
  mdAndUp: boolean
  lgAndDown: boolean
  lgAndUp: boolean
  xlAndDown: boolean
  xlAndUp: boolean
}

// Default (no provider, e.g. unit tests): a desktop xl viewport.
const desktop: BreakpointState = {
  name: 'xl', isXs: false, isSm: false, isMd: false, isLg: false, isXl: true, is2xl: false,
  smAndDown: false, smAndUp: true, mdAndDown: false, mdAndUp: true, lgAndDown: false, lgAndUp: true,
  xlAndDown: true, xlAndUp: true,
}

export const BreakpointsContext = createContext<BreakpointState>(desktop)
export const useBreakpointsContext = () => useContext(BreakpointsContext)
