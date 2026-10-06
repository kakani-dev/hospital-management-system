import { createClient, type SupabaseClient } from '@supabase/supabase-js'

/**
 * Browser Supabase client (Auth only — data goes through the HMS API).
 * Uses the PUBLIC publishable/anon key. Never put a service-role/secret key in VITE_* variables:
 * everything in VITE_* is shipped to every browser.
 */
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? import.meta.env.VITE_SUPABASE_ANON_KEY) as string | undefined

export const supabaseConfigured = Boolean(url && key)

export const supabase: SupabaseClient | null = supabaseConfigured
  ? createClient(url!, key!, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'hms.auth' },
    })
  : null
