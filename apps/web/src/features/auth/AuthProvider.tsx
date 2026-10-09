import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { Session, SupabaseClient } from '@supabase/supabase-js'
import { useQueryClient } from '@tanstack/react-query'
import { apiClient, configureApiAuth, configureResolvedTenantListener, configureUnauthorizedHandler } from '../../lib/api/client'
import { queryKeys } from '../../lib/api/hooks'
import type { CurrentUser } from '../../lib/api/types'
import { openAuthChannel, type AuthChannel } from '../../lib/auth/authChannel'
import { tenantFromAccessToken } from '../../lib/auth/jwt'
import { idleTimeoutMs as configuredIdleTimeoutMs } from '../../lib/config'
import { useIdleTimeout } from './useIdleTimeout'

/** The subset of supabase.auth the app uses (lets tests inject a fake). */
export type AuthClient = Pick<
  SupabaseClient['auth'],
  'getSession' | 'onAuthStateChange' | 'signInWithPassword' | 'signOut' | 'refreshSession'
>

/**
 * Why the user is on the login page. 'user' = they clicked Sign out; 'idle' = automatic logoff;
 * 'ended' = the session ended elsewhere (another tab signed out, or the token refresh failed).
 */
export type SignOutReason = 'user' | 'idle' | 'ended'

/** Raised when the API/token resolves a different tenant than the one on screen (M3). */
export interface TenantNotice {
  previousTenantId: string
  previousTenantName: string | null
  resolvedTenantId: string
  source: 'token' | 'header'
}

interface AuthContextValue {
  configured: boolean
  loading: boolean
  session: Session | null
  email: string | null
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: (reason?: SignOutReason) => Promise<void>
  /** Re-issues the access token so the custom access token hook stamps the new active tenant. */
  refresh: () => Promise<void>
  /** Drops every cached query (PHI) and remounts the routes so nothing stale stays on screen. */
  resetCache: () => void
  /** Bumped by resetCache; App keys its routes on it. */
  cacheEpoch: number
  /** Declares an intentional switch to `tenantId` so the tenant guard does not flag it (null = done). */
  expectTenant: (tenantId: string | null) => void
  tenantNotice: TenantNotice | null
  dismissTenantNotice: () => void
  signedOutReason: SignOutReason | null
}

const AuthContext = createContext<AuthContextValue | null>(null)

const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now())

export function AuthProvider({
  client,
  children,
  idleTimeoutMs = configuredIdleTimeoutMs,
  warmup = apiClient.warmup,
}: {
  client: AuthClient | null
  children: ReactNode
  /** Idle auto-logoff; defaults to VITE_IDLE_TIMEOUT_MINUTES (15 min). */
  idleTimeoutMs?: number
  /** Fire-and-forget wake-up of the edge after each successful sign-in (GET /api/v1/warmup). */
  warmup?: () => void | Promise<void>
}) {
  const queryClient = useQueryClient()
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(client !== null)
  const [cacheEpoch, setCacheEpoch] = useState(0)
  const [tenantNotice, setTenantNotice] = useState<TenantNotice | null>(null)
  const [signedOutReason, setSignedOutReason] = useState<SignOutReason | null>(null)

  const userIdRef = useRef<string | null>(null)
  const expectedTenantRef = useRef<string | null>(null)
  const lastResetAtRef = useRef(Number.NEGATIVE_INFINITY)
  const pendingSignOutReasonRef = useRef<SignOutReason | null>(null)
  const channelRef = useRef<AuthChannel | null>(null)

  const resetCache = useCallback(() => {
    queryClient.clear()
    lastResetAtRef.current = now()
    setCacheEpoch((e) => e + 1)
  }, [queryClient])

  const expectTenant = useCallback((tenantId: string | null) => {
    expectedTenantRef.current = tenantId
    if (tenantId) setTenantNotice(null)
  }, [])

  /**
   * M3 option (b): compare the tenant the server resolved (fresh token claim or X-Hms-Tenant header)
   * with the tenant on screen. On mismatch, drop every cached query and tell the user.
   */
  const checkResolvedTenant = useCallback(
    (resolved: string | null, source: TenantNotice['source'], requestStartedAt = now()) => {
      if (!resolved) return
      if (requestStartedAt < lastResetAtRef.current) return // answer to a request from before the last reset
      if (expectedTenantRef.current && resolved === expectedTenantRef.current) return // intentional switch in flight
      const me = queryClient.getQueryData<CurrentUser>(queryKeys.me)
      const displayed = me?.activeTenantId
      if (!displayed || displayed === resolved) return
      const previousTenantName = me.memberships.find((m) => m.tenantId === displayed)?.tenantName ?? null
      resetCache()
      setTenantNotice({ previousTenantId: displayed, previousTenantName, resolvedTenantId: resolved, source })
    },
    [queryClient, resetCache],
  )

  const handleSignedOut = useCallback(
    (reason: SignOutReason) => {
      userIdRef.current = null
      expectedTenantRef.current = null
      setSession(null)
      setLoading(false)
      setTenantNotice(null)
      setSignedOutReason(reason === 'user' ? null : reason)
      resetCache()
    },
    [resetCache],
  )

  /**
   * Drops this tab's own stored session (sessionStorage) after a sign-out that happened elsewhere
   * (another tab's sign-out/idle logoff, broadcast by supabase-js or our channel). Otherwise a
   * reload would resurrect a session the user ended. No-op when nothing is stored (e.g. a failed
   * refresh, where supabase-js already removed it), which also ends any cross-tab ping-pong.
   */
  const purgeLocalSession = useCallback(async () => {
    if (!client) return
    try {
      const { data } = await client.getSession()
      if (!data.session) return
      pendingSignOutReasonRef.current = 'ended'
      await client.signOut({ scope: 'local' })
    } catch {
      /* best effort */
    } finally {
      pendingSignOutReasonRef.current = null
    }
  }, [client])

  useEffect(() => {
    if (!client) return
    let active = true
    void client.getSession().then(({ data }) => {
      if (!active) return
      userIdRef.current = data.session?.user.id ?? null
      setSession(data.session)
      setLoading(false)
    })
    const { data } = client.onAuthStateChange((event, next) => {
      // SIGNED_OUT covers: our own sign-out, sign-out broadcast by supabase-js from another tab,
      // and a failed token refresh (supabase-js removes the session and emits SIGNED_OUT).
      if (event === 'SIGNED_OUT' || (!next && userIdRef.current)) {
        const initiatedHere = pendingSignOutReasonRef.current !== null
        handleSignedOut(pendingSignOutReasonRef.current ?? 'ended')
        // Never call supabase.auth inside this callback (it holds the auth lock): defer.
        if (!initiatedHere) setTimeout(() => void purgeLocalSession(), 0)
        return
      }
      const nextUser = next?.user.id ?? null
      if (userIdRef.current && nextUser && nextUser !== userIdRef.current) resetCache() // different user: never reuse cache
      userIdRef.current = nextUser
      setSession(next)
      setLoading(false)
      if (event === 'TOKEN_REFRESHED') checkResolvedTenant(tenantFromAccessToken(next?.access_token), 'token')
    })
    return () => {
      active = false
      data.subscription.unsubscribe()
    }
  }, [client, checkResolvedTenant, handleSignedOut, resetCache, purgeLocalSession])

  // Explicit sign-out in another HMS tab: drop this tab's own (sessionStorage) copy of the session too.
  useEffect(() => {
    const channel = openAuthChannel((message) => {
      if (message.type !== 'signed-out') return
      // supabase-js's own SIGNED_OUT broadcast may have arrived first and already cleared the UI.
      if (userIdRef.current) handleSignedOut('ended')
      void purgeLocalSession()
    })
    channelRef.current = channel
    return () => {
      channel.close()
      channelRef.current = null
    }
  }, [handleSignedOut, purgeLocalSession])

  // The API client always asks Supabase for the current (auto-refreshed) access token.
  useEffect(() => {
    configureApiAuth(client ? async () => (await client.getSession()).data.session?.access_token ?? null : () => null)
  }, [client])

  /*
   * A 401 from the API refreshes the session once (shared by concurrent requests) and the request
   * is replayed. A failed refresh does NOT sign out from here: if the refresh token is really dead,
   * supabase-js emits SIGNED_OUT itself; a cold server (5xx/timeout) never ends the session.
   */
  const refreshInFlightRef = useRef<Promise<boolean> | null>(null)
  useEffect(() => {
    if (!client) {
      configureUnauthorizedHandler(null)
      return
    }
    configureUnauthorizedHandler(() => {
      refreshInFlightRef.current ??= (async () => {
        try {
          const { data: current } = await client.getSession()
          if (!current.session) return false
          const { data, error } = await client.refreshSession()
          return !error && !!data.session
        } catch {
          return false
        } finally {
          setTimeout(() => (refreshInFlightRef.current = null), 0)
        }
      })()
      return refreshInFlightRef.current
    })
    return () => configureUnauthorizedHandler(null)
  }, [client])

  // Every API response's X-Hms-Tenant header is checked against the tenant on screen.
  useEffect(() => {
    configureResolvedTenantListener((tenantId, requestStartedAt) => checkResolvedTenant(tenantId, 'header', requestStartedAt))
    return () => configureResolvedTenantListener(null)
  }, [checkResolvedTenant])

  const signIn = useCallback(
    async (email: string, password: string) => {
      if (!client) return { error: 'Authentication is not configured.' }
      const { data, error } = await client.signInWithPassword({ email, password })
      if (error) return { error: error.message || 'Sign-in failed.' }
      queryClient.clear()
      userIdRef.current = data.session?.user.id ?? null
      setSignedOutReason(null)
      setTenantNotice(null)
      setSession(data.session)
      void warmup()
      return { error: null }
    },
    [client, queryClient, warmup],
  )

  const signOut = useCallback(
    async (reason: SignOutReason = 'user') => {
      pendingSignOutReasonRef.current = reason
      try {
        // Automatic logoff only ends this session; an explicit sign-out keeps supabase-js's default.
        if (client) await client.signOut(reason === 'idle' ? { scope: 'local' } : undefined)
      } catch {
        /* still clear everything locally */
      } finally {
        pendingSignOutReasonRef.current = null
        handleSignedOut(reason)
        channelRef.current?.post({ type: 'signed-out' })
      }
    },
    [client, handleSignedOut],
  )

  const refresh = useCallback(async () => {
    if (!client) return
    const { data, error } = await client.refreshSession()
    if (error) throw new Error(error.message || 'Could not refresh the session.')
    setSession(data.session)
  }, [client])

  const onIdle = useCallback(() => void signOut('idle'), [signOut])
  useIdleTimeout({ enabled: session !== null, timeoutMs: idleTimeoutMs, onTimeout: onIdle })

  const dismissTenantNotice = useCallback(() => setTenantNotice(null), [])

  const value = useMemo<AuthContextValue>(
    () => ({
      configured: client !== null,
      loading,
      session,
      email: session?.user.email ?? null,
      signIn,
      signOut,
      refresh,
      resetCache,
      cacheEpoch,
      expectTenant,
      tenantNotice,
      dismissTenantNotice,
      signedOutReason,
    }),
    [client, loading, session, signIn, signOut, refresh, resetCache, cacheEpoch, expectTenant, tenantNotice, dismissTenantNotice, signedOutReason],
  )
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within AuthProvider')
  return ctx
}
