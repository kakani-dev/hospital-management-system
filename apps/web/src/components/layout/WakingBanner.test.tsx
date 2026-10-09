import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WakingBanner } from './WakingBanner'
import { beginPending, resetPending, type PendingHandle } from '../../lib/api/pending'

function renderBanner() {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <WakingBanner afterMs={4_000} stillAfterMs={60_000} />
    </QueryClientProvider>,
  )
}

describe('WakingBanner', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    resetPending()
  })
  afterEach(() => {
    act(() => resetPending())
    vi.useRealTimers()
  })

  it('stays hidden for quick requests', () => {
    renderBanner()
    let req!: PendingHandle
    act(() => {
      req = beginPending()
    })
    act(() => vi.advanceTimersByTime(3_999))
    act(() => req.end())
    act(() => vi.advanceTimersByTime(10_000))
    expect(screen.queryByTestId('waking-banner')).not.toBeInTheDocument()
  })

  it('says "waking" after 4 s, offers "Retry now" after 60 s, and disappears when the request settles', () => {
    renderBanner()
    let req!: PendingHandle
    act(() => {
      req = beginPending()
    })
    act(() => vi.advanceTimersByTime(4_000))
    expect(screen.getByTestId('waking-banner')).toHaveTextContent(/waking the server/i)
    expect(screen.queryByRole('button', { name: 'Retry now' })).not.toBeInTheDocument()
    act(() => vi.advanceTimersByTime(56_000))
    expect(screen.getByTestId('waking-banner')).toHaveAttribute('data-phase', 'still')
    expect(screen.getByRole('button', { name: 'Retry now' })).toBeInTheDocument()
    act(() => req.end())
    expect(screen.queryByTestId('waking-banner')).not.toBeInTheDocument()
  })

  it('"Retry now" skips the backoff wait of requests that are waiting to retry', () => {
    renderBanner()
    let req!: PendingHandle
    act(() => {
      req = beginPending()
    })
    const kick = vi.fn()
    req.setKick(kick)
    act(() => vi.advanceTimersByTime(60_000))
    act(() => screen.getByRole('button', { name: 'Retry now' }).click())
    expect(kick).toHaveBeenCalledTimes(1)
  })

  it('times from the OLDEST pending request', () => {
    renderBanner()
    let first!: PendingHandle
    act(() => {
      first = beginPending()
    })
    act(() => vi.advanceTimersByTime(3_000))
    let second!: PendingHandle
    act(() => {
      second = beginPending()
    })
    act(() => vi.advanceTimersByTime(1_000))
    expect(screen.getByTestId('waking-banner')).toBeInTheDocument()
    act(() => first.end())
    // second has only waited 1 s
    expect(screen.queryByTestId('waking-banner')).not.toBeInTheDocument()
    act(() => vi.advanceTimersByTime(3_000))
    expect(screen.getByTestId('waking-banner')).toBeInTheDocument()
    act(() => second.end())
  })
})
