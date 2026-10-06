import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, renderHook, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { App } from '../../App'
import { AUTH_CHANNEL_NAME } from '../../lib/auth/authChannel'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { AuthProvider, useAuth } from './AuthProvider'
import { useIdleTimeout } from './useIdleTimeout'

const MINUTE = 60_000

beforeEach(() => {
  // Only timers + Date: microtasks and message ports (BroadcastChannel) keep running for real.
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] })
})
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

const flush = () => act(async () => {})
const advance = (ms: number) => act(async () => void (await vi.advanceTimersByTimeAsync(ms)))

describe('useIdleTimeout', () => {
  it('fires once after the timeout without activity', () => {
    const onTimeout = vi.fn()
    renderHook(() => useIdleTimeout({ enabled: true, timeoutMs: 15 * MINUTE, onTimeout }))
    act(() => void vi.advanceTimersByTime(15 * MINUTE - 1))
    expect(onTimeout).not.toHaveBeenCalled()
    act(() => void vi.advanceTimersByTime(1))
    expect(onTimeout).toHaveBeenCalledTimes(1)
    act(() => void vi.advanceTimersByTime(60 * MINUTE))
    expect(onTimeout).toHaveBeenCalledTimes(1)
  })

  it.each(['keyDown', 'pointerDown', 'pointerMove', 'wheel', 'touchStart', 'scroll'] as const)('%s activity resets the timer', (event) => {
    const onTimeout = vi.fn()
    renderHook(() => useIdleTimeout({ enabled: true, timeoutMs: 15 * MINUTE, onTimeout }))
    act(() => void vi.advanceTimersByTime(10 * MINUTE))
    fireEvent[event](event === 'scroll' ? document : window)
    act(() => void vi.advanceTimersByTime(10 * MINUTE))
    expect(onTimeout).not.toHaveBeenCalled()
    act(() => void vi.advanceTimersByTime(5 * MINUTE))
    expect(onTimeout).toHaveBeenCalledTimes(1)
  })

  it('does nothing while disabled (signed out) and stops when unmounted', () => {
    const onTimeout = vi.fn()
    const { rerender, unmount } = renderHook(({ enabled }) => useIdleTimeout({ enabled, timeoutMs: MINUTE, onTimeout }), {
      initialProps: { enabled: false },
    })
    act(() => void vi.advanceTimersByTime(10 * MINUTE))
    expect(onTimeout).not.toHaveBeenCalled()
    rerender({ enabled: true })
    unmount()
    act(() => void vi.advanceTimersByTime(10 * MINUTE))
    expect(onTimeout).not.toHaveBeenCalled()
  })

  it('re-checks the deadline when the tab becomes visible (background timers are throttled)', () => {
    const onTimeout = vi.fn()
    renderHook(() => useIdleTimeout({ enabled: true, timeoutMs: 15 * MINUTE, onTimeout }))
    // The clock moves on (laptop asleep / tab throttled) but the timer has not fired yet.
    vi.setSystemTime(Date.now() + 20 * MINUTE)
    expect(onTimeout).not.toHaveBeenCalled()
    act(() => void document.dispatchEvent(new Event('visibilitychange')))
    expect(onTimeout).toHaveBeenCalledTimes(1)
  })

  it('activity in another HMS tab keeps this tab alive', async () => {
    const onTimeout = vi.fn()
    renderHook(() => useIdleTimeout({ enabled: true, timeoutMs: 15 * MINUTE, onTimeout }))
    act(() => void vi.advanceTimersByTime(14 * MINUTE))

    const otherTab = new BroadcastChannel(AUTH_CHANNEL_NAME)
    const probe = new BroadcastChannel(AUTH_CHANNEL_NAME)
    const delivered = new Promise<void>((resolve) => (probe.onmessage = () => resolve()))
    otherTab.postMessage({ type: 'activity' })
    await delivered
    // setTimeout is faked; let the other channel's queued delivery run on a real macrotask.
    await new Promise((r) => (globalThis as unknown as { setImmediate: (cb: () => void) => void }).setImmediate(() => r(undefined)))
    otherTab.close()
    probe.close()

    act(() => void vi.advanceTimersByTime(14 * MINUTE))
    expect(onTimeout).not.toHaveBeenCalled()
    act(() => void vi.advanceTimersByTime(MINUTE))
    expect(onTimeout).toHaveBeenCalledTimes(1)
  })
})

function Probe() {
  const { session, signedOutReason } = useAuth()
  return <p data-testid="probe">{session ? 'signed-in' : `signed-out:${signedOutReason}`}</p>
}

describe('idle auto-logoff in AuthProvider', () => {
  function renderProbe(idleTimeoutMs?: number) {
    const auth = fakeAuthClient({ session: fakeSession() })
    const queryClient = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } }) // no GC during the long fake wait
    queryClient.setQueryData(['patients', { search: '' }], { items: [{ id: 'p1' }] })
    render(
      <QueryClientProvider client={queryClient}>
        <AuthProvider client={auth} idleTimeoutMs={idleTimeoutMs}>
          <Probe />
        </AuthProvider>
      </QueryClientProvider>,
    )
    return { auth, queryClient }
  }

  it('signs out after 15 idle minutes by default and clears the query cache', async () => {
    const { auth, queryClient } = renderProbe()
    await flush()
    expect(screen.getByTestId('probe')).toHaveTextContent('signed-in')

    await advance(15 * MINUTE - 1)
    expect(auth.signOut).not.toHaveBeenCalled()
    await advance(1)

    expect(auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
    expect(screen.getByTestId('probe')).toHaveTextContent('signed-out:idle')
    expect(queryClient.getQueryData(['patients', { search: '' }])).toBeUndefined()
  })

  it('honours a configured timeout and resets on activity', async () => {
    const { auth } = renderProbe(2 * MINUTE)
    await flush()
    await advance(90_000)
    fireEvent.keyDown(window, { key: 'a' })
    await advance(90_000)
    expect(auth.signOut).not.toHaveBeenCalled()
    await advance(30_000)
    expect(auth.signOut).toHaveBeenCalledTimes(1)
  })

  it('shows the inactivity notice on the login page', async () => {
    stubFetch({ 'GET /api/v1/me': () => json(meFor()), 'GET /health/live': () => json({ status: 'Healthy' }) })
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }), idleTimeoutMs: 5 * MINUTE })
    await flush()
    expect(screen.getByRole('heading', { name: /dashboard/i })).toBeInTheDocument()
    await advance(5 * MINUTE)
    expect(screen.getByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
    expect(screen.getByText(/signed out after a period of inactivity/i)).toBeInTheDocument()
  })
})
