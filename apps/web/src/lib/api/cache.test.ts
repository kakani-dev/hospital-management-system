import { describe, expect, it, vi, afterEach } from 'vitest'
import { QueryClient } from '@tanstack/react-query'
import { renderHook, waitFor } from '@testing-library/react'
import { createElement, type ReactNode } from 'react'
import { QueryClientProvider } from '@tanstack/react-query'
import { CACHE_TIERS, ME_STALE_TIME, cacheTierFor, configureCachePolicy } from './cachePolicy'
import { PERSIST_MAX_AGE_MS, clearPersistedCache, isPersistable, persistKey, restoreCache, saveCache, startPersisting } from './cachePersist'
import { queryKeys, useCreateAppointment, useUpdateBranch } from './hooks'
import { json, stubFetch } from '../../test/fakes'

const client = () => configureCachePolicy(new QueryClient({ defaultOptions: { queries: { retry: false } } }))
const ALICE = { userId: 'u-alice', tenantId: 't-alpha' }

afterEach(() => {
  sessionStorage.clear()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('cache policy tiers', () => {
  it('maps query roots to tiers', () => {
    expect(cacheTierFor(queryKeys.me)).toBe('reference')
    expect(cacheTierFor(queryKeys.branches)).toBe('reference')
    expect(cacheTierFor(queryKeys.currentTenant)).toBe('reference')
    expect(cacheTierFor(queryKeys.branchPractitioners('b'))).toBe('reference')
    expect(cacheTierFor(queryKeys.patient('p'))).toBe('phi')
    expect(cacheTierFor(queryKeys.patients({}))).toBe('phi')
    expect(cacheTierFor(queryKeys.slots('b', 'p', '2026-10-20'))).toBe('live')
    expect(cacheTierFor(queryKeys.queue('b', '2026-10-20'))).toBe('live')
  })

  it('applies TTLs through query defaults', () => {
    const qc = client()
    expect(qc.getQueryDefaults(queryKeys.branches).staleTime).toBe(CACHE_TIERS.reference.staleTime)
    expect(qc.getQueryDefaults(queryKeys.me).staleTime).toBe(ME_STALE_TIME)
    expect(qc.getQueryDefaults(queryKeys.patient('p')).staleTime).toBe(CACHE_TIERS.phi.staleTime)
    const live = qc.getQueryDefaults(queryKeys.slots('b', 'p', 'd'))
    expect(live.staleTime).toBeLessThanOrEqual(30_000)
    expect(live.refetchOnWindowFocus).toBe(true)
    expect(qc.getQueryDefaults(queryKeys.inviteLinks).staleTime).toBe(0)
  })

  it('serves a fresh reference query from cache and dedupes concurrent fetches', async () => {
    const qc = client()
    const fn = vi.fn(async () => [{ id: 'b1' }])
    await Promise.all([qc.fetchQuery({ queryKey: queryKeys.branches, queryFn: fn }), qc.fetchQuery({ queryKey: queryKeys.branches, queryFn: fn })])
    await qc.fetchQuery({ queryKey: queryKeys.branches, queryFn: fn })
    expect(fn).toHaveBeenCalledTimes(1)
  })
})

describe('sessionStorage persistence', () => {
  it('persists reference queries only (never PHI, live data or invite links)', () => {
    expect(isPersistable(queryKeys.me)).toBe(true)
    expect(isPersistable(queryKeys.branches)).toBe(true)
    expect(isPersistable(queryKeys.patient('p'))).toBe(false)
    expect(isPersistable(queryKeys.patients({ search: 'x' }))).toBe(false)
    expect(isPersistable(queryKeys.queue('b', 'd'))).toBe(false)
    expect(isPersistable(queryKeys.inviteLinks)).toBe(false)
    const qc = client()
    qc.setQueryData(queryKeys.branches, [{ id: 'b1' }])
    qc.setQueryData(queryKeys.patient('p1'), { id: 'p1', firstName: 'Synthetic' })
    saveCache(qc, ALICE)
    const raw = sessionStorage.getItem(persistKey(ALICE))!
    expect(raw).toContain('b1')
    expect(raw).not.toContain('Synthetic')
  })

  it('restores only for the same user and tenant, and not after expiry', () => {
    const qc = client()
    qc.setQueryData(queryKeys.branches, [{ id: 'b1' }])
    saveCache(qc, ALICE, 1_000)
    const other = client()
    expect(restoreCache(other, { userId: 'u-alice', tenantId: 't-beta' }, 2_000)).toBe(0)
    expect(restoreCache(other, { userId: 'u-bob', tenantId: 't-alpha' }, 2_000)).toBe(0)
    expect(other.getQueryData(queryKeys.branches)).toBeUndefined()
    expect(restoreCache(other, ALICE, 2_000)).toBe(1)
    expect(other.getQueryData(queryKeys.branches)).toEqual([{ id: 'b1' }])
    expect(restoreCache(client(), ALICE, 1_000 + PERSIST_MAX_AGE_MS + 1)).toBe(0)
    expect(sessionStorage.getItem(persistKey(ALICE))).toBeNull()
  })

  it('clearPersistedCache removes every user/tenant entry', () => {
    const qc = client()
    qc.setQueryData(queryKeys.branches, [])
    saveCache(qc, ALICE)
    saveCache(qc, { userId: 'u-bob', tenantId: null })
    sessionStorage.setItem('unrelated', '1')
    clearPersistedCache()
    expect(Object.keys(sessionStorage)).toEqual(['unrelated'])
  })

  it('startPersisting saves after a reference query succeeds', async () => {
    const qc = client()
    const stop = startPersisting(qc, () => ALICE, 0)
    await qc.fetchQuery({ queryKey: queryKeys.branches, queryFn: async () => [{ id: 'b9' }] })
    await waitFor(() => expect(sessionStorage.getItem(persistKey(ALICE))).toContain('b9'))
    stop()
  })
})

describe('invalidation after writes', () => {
  const wrapper = (qc: QueryClient) => ({ children }: { children: ReactNode }) => createElement(QueryClientProvider, { client: qc }, children)

  it('a booking invalidates appointments, slots and the queue, but not reference data', async () => {
    stubFetch({ 'POST /api/v1/appointments': () => json({ id: 'a1' }, 201) })
    const qc = client()
    qc.setQueryData(queryKeys.slots('b', 'p', 'd'), [])
    qc.setQueryData(queryKeys.queue('b', 'd'), [])
    qc.setQueryData(queryKeys.appointments({ branchId: 'b', from: 'f', to: 't' }), [])
    qc.setQueryData(queryKeys.branches, [])
    const { result } = renderHook(() => useCreateAppointment(), { wrapper: wrapper(qc) })
    await result.current.mutateAsync({ branchId: 'b', practitionerId: 'p', patientId: 'x', startsAt: 's', endsAt: 'e' })
    expect(qc.getQueryState(queryKeys.slots('b', 'p', 'd'))!.isInvalidated).toBe(true)
    expect(qc.getQueryState(queryKeys.queue('b', 'd'))!.isInvalidated).toBe(true)
    expect(qc.getQueryState(queryKeys.appointments({ branchId: 'b', from: 'f', to: 't' }))!.isInvalidated).toBe(true)
    expect(qc.getQueryState(queryKeys.branches)!.isInvalidated).toBe(false)
  })

  it('a branch edit invalidates branches and /me', async () => {
    stubFetch({ 'PATCH /api/v1/branches/b1': () => json({ id: 'b1' }) })
    const qc = client()
    qc.setQueryData(queryKeys.branches, [])
    qc.setQueryData(queryKeys.me, {})
    qc.setQueryData(queryKeys.queue('b', 'd'), [])
    const { result } = renderHook(() => useUpdateBranch(), { wrapper: wrapper(qc) })
    await result.current.mutateAsync({ id: 'b1', body: { name: 'Renamed' } as never })
    expect(qc.getQueryState(queryKeys.branches)!.isInvalidated).toBe(true)
    expect(qc.getQueryState(queryKeys.me)!.isInvalidated).toBe(true)
    expect(qc.getQueryState(queryKeys.queue('b', 'd'))!.isInvalidated).toBe(false)
  })
})
