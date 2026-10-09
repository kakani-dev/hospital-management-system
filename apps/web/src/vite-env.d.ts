/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL?: string
  readonly VITE_SUPABASE_URL?: string
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string
  readonly VITE_SUPABASE_ANON_KEY?: string
  /** Idle auto-logoff in minutes (default 15). */
  readonly VITE_IDLE_TIMEOUT_MINUTES?: string
  /** Resilience settings (lib/config.ts resilienceConfigFrom); all in ms except the counts. */
  readonly VITE_API_GET_TIMEOUT_MS?: string
  readonly VITE_API_WRITE_TIMEOUT_MS?: string
  readonly VITE_API_RETRY_COUNT?: string
  readonly VITE_API_RETRY_BASE_DELAY_MS?: string
  readonly VITE_API_RETRY_FACTOR?: string
  readonly VITE_API_RETRY_MAX_DELAY_MS?: string
  readonly VITE_WAKING_BANNER_AFTER_MS?: string
  readonly VITE_WAKING_STILL_AFTER_MS?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
