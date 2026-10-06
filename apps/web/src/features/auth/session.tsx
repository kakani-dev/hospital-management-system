import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'
import type { MembershipDto } from '../../lib/api/types'
import { DEMO_MEMBERSHIPS } from '../tenancy/demoMemberships'

export interface Session {
  email: string
  memberships: MembershipDto[]
  activeTenantId: string
  activeBranchId: string | null
}

interface SessionContextValue {
  session: Session | null
  activeMembership: MembershipDto | null
  signInDemo: (email: string) => void
  signOut: () => void
  switchBranch: (branchId: string) => void
}

const STORAGE_KEY = 'hms.demo-session'
const SessionContext = createContext<SessionContextValue | null>(null)

function loadSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY)
    return raw ? (JSON.parse(raw) as Session) : null
  } catch {
    return null
  }
}

export function SessionProvider({ children, initialSession }: { children: ReactNode; initialSession?: Session | null }) {
  const [session, setSession] = useState<Session | null>(() => initialSession ?? loadSession())

  const persist = useCallback((next: Session | null) => {
    setSession(next)
    if (next) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next))
    else sessionStorage.removeItem(STORAGE_KEY)
  }, [])

  // Sprint 0 placeholder: no credentials are checked and no token is issued.
  // TODO(Sprint 1): replace with Supabase Auth sign-in, then load memberships from GET /api/v1/me.
  const signInDemo = useCallback(
    (email: string) => {
      const first = DEMO_MEMBERSHIPS[0]!
      persist({ email, memberships: DEMO_MEMBERSHIPS, activeTenantId: first.tenantId, activeBranchId: first.branchId })
    },
    [persist],
  )

  const signOut = useCallback(() => persist(null), [persist])

  const switchBranch = useCallback(
    (branchId: string) => {
      if (!session) return
      // Only branches the session already has a membership for can be selected.
      // The backend still re-validates membership on every request.
      const target = session.memberships.find((m) => m.branchId === branchId && m.tenantId === session.activeTenantId)
      if (target) persist({ ...session, activeBranchId: branchId })
    },
    [session, persist],
  )

  const activeMembership = useMemo(
    () =>
      session?.memberships.find((m) => m.tenantId === session.activeTenantId && m.branchId === session.activeBranchId) ??
      null,
    [session],
  )

  const value = useMemo(
    () => ({ session, activeMembership, signInDemo, signOut, switchBranch }),
    [session, activeMembership, signInDemo, signOut, switchBranch],
  )
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useSession(): SessionContextValue {
  const ctx = useContext(SessionContext)
  if (!ctx) throw new Error('useSession must be used within SessionProvider')
  return ctx
}
