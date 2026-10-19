import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError, ApiTransportError, isTransientError, parseRetryAfter, retryDelayMs } from './client'
import { oldestPendingStart, resetPending, retryPendingNow } from './pending'
import { resilienceConfigFrom } from '../config'

const ok = (body: unknown = { status: 'ok' }) => new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })
const problem = (status: number, headers: Record<string, string> = {}, code = 'service_unavailable') =>
  new Response(JSON.stringify({ title: 'Service unavailable', status, code }), { status, headers: { 'Content-Type': 'application/problem+json', ...headers } })

/** fetch that never answers but honours the abort signal, like a real hung connection. */
const hanging = () =>
  vi.fn(
    (_input: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('The operation was aborted.', 'AbortError')))
      }),
  )

const fast = { retryCount: 3, retryBaseDelayMs: 1_000, retryFactor: 3, retryMaxDelayMs: 30_000, getTimeoutMs: 40_000, writeTimeoutMs: 40_000 }

describe('ApiClient resilience', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    resetPending()
  })
  afterEach(() => {
    vi.useRealTimers()
    resetPending()
  })

  it('retries a GET on 503 honouring Retry-After: 5 until it succeeds', async () => {
    const fetchImpl = vi.fn().mockResolvedValueOnce(problem(503, { 'Retry-After': '5' })).mockResolvedValueOnce(problem(503, { 'Retry-After': '5' })).mockResolvedValueOnce(ok({ userId: 'u' }))
    const client = new ApiClient({ fetchImpl, resilience: fast, random: () => 0.5 })
    const result = client.me()
    await vi.advanceTimersByTimeAsync(4_999)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(5_000)
    await expect(result).resolves.toEqual({ userId: 'u' })
    expect(fetchImpl).toHaveBeenCalledTimes(3)
  })

  it.each([502, 504, 429])('retries a GET on %i with exponential backoff (1 s, 3 s, 9 s) and then gives up', async (status) => {
    const fetchImpl = vi.fn().mockImplementation(async () => problem(status, {}, 'x'))
    const client = new ApiClient({ fetchImpl, resilience: fast, random: () => 0.5 })
    const result = client.me().catch((e: unknown) => e)
    await vi.advanceTimersByTimeAsync(999)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetchImpl).toHaveBeenCalledTimes(3)
    await vi.advanceTimersByTimeAsync(9_000)
    expect(fetchImpl).toHaveBeenCalledTimes(4)
    const error = await result
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).status).toBe(status)
  })

  it('retries a GET after a network error', async () => {
    const fetchImpl = vi.fn().mockRejectedValueOnce(new TypeError('Failed to fetch')).mockResolvedValueOnce(ok())
    const client = new ApiClient({ fetchImpl, resilience: fast, random: () => 0.5 })
    const result = client.health.live()
    await vi.advanceTimersByTimeAsync(1_000)
    await expect(result).resolves.toEqual({ status: 'ok' })
    expect(fetchImpl).toHaveBeenCalledTimes(2)
  })

  it.each([400, 403, 404, 409, 500])('does not retry a GET on %i', async (status) => {
    const fetchImpl = vi.fn().mockResolvedValue(problem(status, {}, 'x'))
    const client = new ApiClient({ fetchImpl, resilience: fast })
    await expect(client.me()).rejects.toMatchObject({ status })
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('times a GET out after getTimeoutMs, retries it, and reports a timeout when all attempts hang', async () => {
    const fetchImpl = hanging()
    const client = new ApiClient({ fetchImpl, resilience: { ...fast, retryCount: 1, getTimeoutMs: 35_000 }, random: () => 0.5 })
    const result = client.me().catch((e: unknown) => e)
    await vi.advanceTimersByTimeAsync(34_999)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1 + 1_000)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(35_000)
    const error = await result
    expect(error).toBeInstanceOf(ApiTransportError)
    expect((error as ApiTransportError).kind).toBe('timeout')
    expect(isTransientError(error)).toBe(true)
  })

  it('never retries a POST: 503 and timeouts surface immediately so the screen can offer Retry', async () => {
    const fetch503 = vi.fn().mockResolvedValue(problem(503, { 'Retry-After': '5' }))
    const client = new ApiClient({ fetchImpl: fetch503, resilience: fast })
    await expect(client.queue.walkIn({ branchId: 'b', patientId: 'p' })).rejects.toMatchObject({ status: 503, retryAfterMs: 5_000 })
    expect(fetch503).toHaveBeenCalledTimes(1)

    const fetchHang = hanging()
    const slow = new ApiClient({ fetchImpl: fetchHang, resilience: { ...fast, writeTimeoutMs: 30_000 } })
    const result = slow.appointments.checkIn('a').catch((e: unknown) => e)
    await vi.advanceTimersByTimeAsync(30_000)
    expect(await result).toMatchObject({ name: 'ApiTransportError', kind: 'timeout' })
    await vi.advanceTimersByTimeAsync(60_000)
    expect(fetchHang).toHaveBeenCalledTimes(1)
  })

  it('a per-call `retry: false` GET is not retried', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(problem(503))
    const client = new ApiClient({ fetchImpl, resilience: fast })
    await expect(client.request('/api/v1/me', { retry: false })).rejects.toMatchObject({ status: 503 })
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('a caller abort stops the retries', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(problem(503, { 'Retry-After': '5' }))
    const client = new ApiClient({ fetchImpl, resilience: fast })
    const controller = new AbortController()
    const result = client.request('/api/v1/me', { signal: controller.signal }).catch((e: unknown) => e)
    await vi.advanceTimersByTimeAsync(10)
    controller.abort()
    expect(await result).toMatchObject({ name: 'AbortError' })
    await vi.advanceTimersByTimeAsync(60_000)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('tracks one pending entry per logical request across retries; "Retry now" skips the backoff wait', async () => {
    vi.setSystemTime(new Date('2026-10-09T10:00:00Z'))
    const fetchImpl = vi.fn().mockResolvedValueOnce(problem(503, { 'Retry-After': '5' })).mockResolvedValueOnce(ok())
    const client = new ApiClient({ fetchImpl, resilience: fast })
    const result = client.me()
    await vi.advanceTimersByTimeAsync(100)
    expect(oldestPendingStart()).toBe(Date.parse('2026-10-09T10:00:00Z'))
    expect(retryPendingNow()).toBe(1)
    await vi.advanceTimersByTimeAsync(0)
    await expect(result).resolves.toEqual({ status: 'ok' })
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    expect(oldestPendingStart()).toBeNull()
  })

  it('after a 401 refreshes once and replays with the new token; a second 401 is final', async () => {
    let token = 'old'
    const onUnauthorized = vi.fn(async () => {
      token = 'new'
      return true
    })
    const fetchImpl = vi.fn().mockResolvedValueOnce(problem(401, {}, 'unauthorized')).mockResolvedValueOnce(ok({ userId: 'u' }))
    const client = new ApiClient({ fetchImpl, getAccessToken: () => token, onUnauthorized, resilience: fast })
    await expect(client.me()).resolves.toEqual({ userId: 'u' })
    expect(new Headers((fetchImpl.mock.calls[1] as [string, RequestInit])[1].headers).get('Authorization')).toBe('Bearer new')

    const always401 = vi.fn().mockImplementation(async () => problem(401, {}, 'unauthorized'))
    const refresh = vi.fn(async () => true)
    const client2 = new ApiClient({ fetchImpl: always401, onUnauthorized: refresh, resilience: fast })
    await expect(client2.patients.create({ firstName: 'A', lastName: 'B', sex: 'unknown', registeredBranchId: 'b' })).rejects.toMatchObject({ status: 401 })
    expect(refresh).toHaveBeenCalledTimes(1)
    expect(always401).toHaveBeenCalledTimes(2)
  })

  it('a failed refresh leaves the 401 to the screen (no replay)', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(problem(401, {}, 'unauthorized'))
    const client = new ApiClient({ fetchImpl, onUnauthorized: async () => false, resilience: fast })
    await expect(client.me()).rejects.toMatchObject({ status: 401 })
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('warm-up: unauthenticated GET /api/v1/warmup, never retried, not tracked, errors swallowed', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(problem(503))
    const getAccessToken = vi.fn(() => 'tkn')
    const client = new ApiClient({ baseUrl: 'https://edge.example.test', fetchImpl, getAccessToken, resilience: fast })
    const done = client.warmup()
    expect(oldestPendingStart()).toBeNull()
    await expect(done).resolves.toBeUndefined()
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://edge.example.test/api/v1/warmup')
    expect(init.method).toBe('GET')
    expect(new Headers(init.headers).has('Authorization')).toBe(false)
    expect(getAccessToken).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(60_000)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })
})

describe('retry helpers', () => {
  it('parses Retry-After as seconds or an HTTP date', () => {
    expect(parseRetryAfter('5')).toBe(5_000)
    expect(parseRetryAfter('0.5')).toBe(500)
    expect(parseRetryAfter(null)).toBeNull()
    expect(parseRetryAfter('soon')).toBeNull()
    const now = Date.parse('2026-10-09T10:00:00Z')
    expect(parseRetryAfter('Fri, 09 Oct 2026 10:00:07 GMT', now)).toBe(7_000)
    expect(parseRetryAfter('Fri, 09 Oct 2026 09:00:00 GMT', now)).toBe(0)
  })

  it('backs off exponentially with ±25 % jitter, prefers Retry-After, and caps every wait', () => {
    const cfg = { retryBaseDelayMs: 1_000, retryFactor: 3, retryMaxDelayMs: 30_000 }
    expect(retryDelayMs(0, new Error('x'), cfg, () => 0)).toBe(750)
    expect(retryDelayMs(0, new Error('x'), cfg, () => 1)).toBe(1_250)
    expect(retryDelayMs(2, new Error('x'), cfg, () => 0.5)).toBe(9_000)
    expect(retryDelayMs(5, new Error('x'), cfg, () => 0.5)).toBe(30_000)
    expect(retryDelayMs(0, new ApiError(503, null, undefined, 5_000), cfg)).toBe(5_000)
    expect(retryDelayMs(0, new ApiError(503, null, undefined, 600_000), cfg)).toBe(30_000)
  })

  it('classifies transient errors', () => {
    expect(isTransientError(new ApiTransportError('network'))).toBe(true)
    expect(isTransientError(new ApiError(503, null))).toBe(true)
    expect(isTransientError(new ApiError(500, null))).toBe(false)
    expect(isTransientError(new ApiError(401, null))).toBe(false)
    expect(isTransientError(new Error('x'))).toBe(false)
  })
})

describe('resilience configuration', () => {
  it('defaults to the CTO contract values', () => {
    expect(resilienceConfigFrom({})).toEqual({
      getTimeoutMs: 40_000,
      writeTimeoutMs: 40_000,
      retryCount: 3,
      retryBaseDelayMs: 1_000,
      retryFactor: 3,
      retryMaxDelayMs: 30_000,
      wakingBannerAfterMs: 4_000,
      wakingStillAfterMs: 60_000,
    })
  })

  it('reads VITE_* overrides, ignores junk and caps silly values', () => {
    const cfg = resilienceConfigFrom({
      VITE_API_GET_TIMEOUT_MS: '35000',
      VITE_API_WRITE_TIMEOUT_MS: 'abc',
      VITE_API_RETRY_COUNT: '0',
      VITE_API_RETRY_BASE_DELAY_MS: '-1',
      VITE_API_RETRY_MAX_DELAY_MS: '99999999',
      VITE_WAKING_BANNER_AFTER_MS: '1000',
      VITE_WAKING_STILL_AFTER_MS: '500',
    })
    expect(cfg.getTimeoutMs).toBe(35_000)
    expect(cfg.writeTimeoutMs).toBe(40_000)
    expect(cfg.retryCount).toBe(0)
    expect(cfg.retryBaseDelayMs).toBe(1_000)
    expect(cfg.retryMaxDelayMs).toBe(300_000)
    expect(cfg.wakingBannerAfterMs).toBe(1_000)
    expect(cfg.wakingStillAfterMs).toBe(1_000) // never before the first banner
  })
})
