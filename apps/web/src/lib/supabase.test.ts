import { describe, expect, it } from 'vitest'
import { authOptions } from './supabase'

describe('Supabase auth options', () => {
  it('persists the session in sessionStorage (per tab, gone with the window), never localStorage', () => {
    const options = authOptions()
    expect(options.storage).toBe(window.sessionStorage)
    expect(options.storage).not.toBe(window.localStorage)
    expect(options).toMatchObject({ persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'hms.auth' })
  })
})
