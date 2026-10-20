import { dehydrate, hydrate, type DehydratedState, type Query, type QueryClient, type QueryKey } from '@tanstack/react-query'
import { cacheTierFor, CACHE_TIERS } from './cachePolicy'

/**
 * Persists reference-tier queries (never PHI) in sessionStorage, keyed by user id + the tenant in
 * the access token, so a reload or a new route is served from cache. Cleared on sign-in, sign-out,
 * tenant switch and any cache reset; entries for another user/tenant are never read.
 */
const PREFIX = 'hms.qc.v1:'
export const PERSIST_MAX_AGE_MS = CACHE_TIERS.reference.gcTime

interface Stored {
  savedAt: number
  state: DehydratedState
}

export interface CacheScope {
  userId: string
  tenantId: string | null
}

export const persistKey = ({ userId, tenantId }: CacheScope) => `${PREFIX}${userId}:${tenantId ?? 'none'}`

export function isPersistable(queryKey: QueryKey): boolean {
  if (queryKey[0] === 'members' && queryKey[1] === 'invite-links') return false
  return cacheTierFor(queryKey) === 'reference'
}

const storage = (): Storage | null => {
  try {
    return typeof sessionStorage === 'undefined' ? null : sessionStorage
  } catch {
    return null
  }
}

/** Hydrates the scope's stored queries; returns how many were restored. */
export function restoreCache(client: QueryClient, scope: CacheScope, now = Date.now()): number {
  const store = storage()
  const raw = store?.getItem(persistKey(scope))
  if (!store || !raw) return 0
  try {
    const stored = JSON.parse(raw) as Stored
    if (!stored.savedAt || now - stored.savedAt > PERSIST_MAX_AGE_MS) {
      store.removeItem(persistKey(scope))
      return 0
    }
    const queries = stored.state.queries.filter((q) => isPersistable(q.queryKey))
    hydrate(client, { ...stored.state, queries, mutations: [] })
    return queries.length
  } catch {
    store.removeItem(persistKey(scope))
    return 0
  }
}

export function saveCache(client: QueryClient, scope: CacheScope, now = Date.now()) {
  const store = storage()
  if (!store) return
  const state = dehydrate(client, { shouldDehydrateQuery: (q: Query) => q.state.status === 'success' && isPersistable(q.queryKey), shouldDehydrateMutation: () => false })
  try {
    store.setItem(persistKey(scope), JSON.stringify({ savedAt: now, state } satisfies Stored))
  } catch {
    /* quota: caching is best effort */
  }
}

/** Removes every persisted cache entry (all users and tenants). */
export function clearPersistedCache() {
  const store = storage()
  if (!store) return
  for (let i = store.length - 1; i >= 0; i--) {
    const k = store.key(i)
    if (k?.startsWith(PREFIX)) store.removeItem(k)
  }
}

/** Saves (debounced) whenever a persistable query succeeds or is removed. Returns an unsubscribe. */
export function startPersisting(client: QueryClient, getScope: () => CacheScope | null, delayMs = 250): () => void {
  let timer: ReturnType<typeof setTimeout> | null = null
  const flush = () => {
    if (timer) clearTimeout(timer)
    timer = null
    const scope = getScope()
    if (scope) saveCache(client, scope)
  }
  // A reload or navigation away must not lose a save that is still debounced.
  const onPageHide = () => {
    if (timer) flush()
  }
  if (typeof window !== 'undefined') window.addEventListener('pagehide', onPageHide)
  const unsubscribe = client.getQueryCache().subscribe((event) => {
    if (!isPersistable(event.query.queryKey)) return
    if (!(event.type === 'removed' || (event.type === 'updated' && event.action.type === 'success'))) return
    if (timer) clearTimeout(timer)
    timer = setTimeout(flush, delayMs)
  })
  return () => {
    if (timer) clearTimeout(timer)
    if (typeof window !== 'undefined') window.removeEventListener('pagehide', onPageHide)
    unsubscribe()
  }
}
