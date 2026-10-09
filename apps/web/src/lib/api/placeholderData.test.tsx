import { describe, expect, it } from 'vitest'
import type { ReactNode } from 'react'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useQueue, useSlots } from './hooks'
import { json, stubFetch } from '../../test/fakes'

const wrapper = ({ children }: { children: ReactNode }) => (
  <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>{children}</QueryClientProvider>
)

describe('placeholder data is only kept for a comparable key', () => {
  it('queue: keeps the board across a date change at the same branch, never across branches', async () => {
    const pending: Record<string, boolean> = { B: true }
    stubFetch({
      'GET /api/v1/queue': (url) => {
        const branch = url.searchParams.get('branchId')!
        if (pending[branch] && url.searchParams.get('date') !== '2026-10-09') return new Promise<Response>(() => {})
        return json([{ id: `${branch}-1`, tokenNo: 1 }])
      },
    })
    const { result, rerender } = renderHook(({ branch, date }) => useQueue(branch, date, { refetchInterval: false }), {
      wrapper,
      initialProps: { branch: 'A', date: '2026-10-09' },
    })
    await waitFor(() => expect(result.current.data?.[0]).toMatchObject({ id: 'A-1' }))

    rerender({ branch: 'B', date: '2026-10-10' })
    expect(result.current.data).toBeUndefined()
    expect(result.current.isPlaceholderData).toBe(false)

    rerender({ branch: 'A', date: '2026-10-09' })
    await waitFor(() => expect(result.current.data?.[0]).toMatchObject({ id: 'A-1' }))
    pending.A = true
    rerender({ branch: 'A', date: '2026-10-10' })
    expect(result.current.isPlaceholderData).toBe(true)
    expect(result.current.data?.[0]).toMatchObject({ id: 'A-1' })
  })

  it('slots: kept (to be shown disabled) for another date of the same practitioner, dropped for another practitioner', async () => {
    stubFetch({
      'GET /api/v1/slots': (url) =>
        url.searchParams.get('from') === '2026-10-09' ? json([{ startsAt: 'x', endsAt: 'y', practitionerId: url.searchParams.get('practitionerId') }]) : new Promise<Response>(() => {}),
    })
    const { result, rerender } = renderHook(({ p, d }) => useSlots('br', p, d), { wrapper, initialProps: { p: 'doc1', d: '2026-10-09' } })
    await waitFor(() => expect(result.current.data).toHaveLength(1))
    rerender({ p: 'doc1', d: '2026-10-10' })
    expect(result.current.isPlaceholderData).toBe(true)
    rerender({ p: 'doc2', d: '2026-10-10' })
    expect(result.current.data).toBeUndefined()
  })
})
