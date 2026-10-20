import type { QueryClient, QueryKey } from '@tanstack/react-query'

/**
 * Cache-first policy: a query is served from the cache while fresh (no request), deduplicated while
 * in flight (TanStack Query shares one promise per key), and refetched only when stale or
 * invalidated by a write. Tiers are keyed by the first query-key segment (see queryKeys).
 *
 * - reference: identity, hospital settings, branches, practitioners, schedules. Long TTL
 *   and persisted per user + tenant in sessionStorage (cachePersist.ts).
 * - phi: patient lists, details, stats. In memory only, short TTL.
 * - shared: member lists (changed by invitees accepting): revalidated on every mount, in memory.
 * - live: appointments, free slots, queue. Very short TTL + refetch on window focus. The server
 *   stays the source of truth for booking conflicts (409s refresh the slots).
 */
export type CacheTier = 'reference' | 'phi' | 'live' | 'platform' | 'shared'

export const CACHE_TIERS = {
  reference: { staleTime: 15 * 60_000, gcTime: 30 * 60_000 },
  phi: { staleTime: 30_000, gcTime: 5 * 60_000 },
  live: { staleTime: 15_000, gcTime: 2 * 60_000, refetchOnWindowFocus: true },
  platform: { staleTime: 60_000, gcTime: 5 * 60_000 },
  // Changed by other people's actions (invitees accepting, admins elsewhere): shown from cache at
  // once but always revalidated on mount; in memory only.
  shared: { staleTime: 0, gcTime: 5 * 60_000 },
} as const

/** /me (memberships + permissions) refreshes sooner than other reference data. */
export const ME_STALE_TIME = 10 * 60_000

const ROOT_TIERS: Record<string, CacheTier> = {
  me: 'reference',
  tenants: 'reference',
  branches: 'reference',
  practitioners: 'reference',
  schedules: 'reference',
  members: 'shared',
  patients: 'phi',
  appointments: 'live',
  queue: 'live',
  platform: 'platform',
}

export function cacheTierFor(queryKey: QueryKey): CacheTier | null {
  const root = queryKey[0]
  return typeof root === 'string' ? (ROOT_TIERS[root] ?? null) : null
}

/** Registers the tier defaults on a client (hooks must not override staleTime for these roots). */
export function configureCachePolicy(client: QueryClient): QueryClient {
  for (const [root, tier] of Object.entries(ROOT_TIERS)) client.setQueryDefaults([root], CACHE_TIERS[tier])
  client.setQueryDefaults(['me'], { ...CACHE_TIERS.reference, staleTime: ME_STALE_TIME })
  // Invite links are one-time secrets shown once: never kept long.
  client.setQueryDefaults(['members', 'invite-links'], { staleTime: 0, gcTime: 60_000 })
  return client
}
