import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session, SupabaseClient } from '@supabase/supabase-js'
import { useQueryClient } from '@tanstack/react-query'
import { configureApiAuth } from '../../lib/api/client'

/** The subset of supabase.auth the app uses (lets tests inject a fake). */
export type AuthClient = Pick<
  SupabaseClient['auth'],
  'getSession' | 'onAuthStateChange' | 'signInWithPassword' | 'signOut' | 'refreshSession'
>

interface AuthContextValue {
  configured: boolean
  loading: boolean
  session: Session | null
  email: string | null
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
  /** Re-issues the access token so the custom access token hook stamps the new active tenant. */
  refresh: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ client, children }: { client: AuthClient | null; children: ReactNode }) {
  const queryClient = useQueryClient()
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(client !== null)

  useEffect(() => {
    if (!client) return
    let active = true
    void client.getSession().then(({ data }) => {
      if (!active) return
      setSession(data.session)
      setLoading(false)
    })
    const { data } = client.onAuthStateChange((_event, next) => {
      setSession(next)
      setLoading(false)
    })
    return () => {
      active = false
      data.subscription.unsubscribe()
    }
  }, [client])

  // The API client always asks Supabase for the current (auto-refreshed) access token.
  useEffect(() => {
    configureApiAuth(client ? async () => (await client.getSession()).data.session?.access_token ?? null : () => null)
  }, [client])

  const signIn = useCallback(
    async (email: string, password: string) => {
      if (!client) return { error: 'Authentication is not configured.' }
      const { data, error } = await client.signInWithPassword({ email, password })
      if (error) return { error: error.message || 'Sign-in failed.' }
      queryClient.clear()
      setSession(data.session)
      return { error: null }
    },
    [client, queryClient],
  )

  const signOut = useCallback(async () => {
    if (client) await client.signOut()
    setSession(null)
    queryClient.clear()
  }, [client, queryClient])

  const refresh = useCallback(async () => {
    if (!client) return
    const { data, error } = await client.refreshSession()
    if (error) throw new Error(error.message || 'Could not refresh the session.')
    setSession(data.session)
  }, [client])

  const value = useMemo<AuthContextValue>(
    () => ({
      configured: client !== null,
      loading,
      session,
      email: session?.user.email ?? null,
      signIn,
      signOut,
      refresh,
    }),
    [client, loading, session, signIn, signOut, refresh],
  )
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within AuthProvider')
  return ctx
}
