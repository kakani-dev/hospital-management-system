import { describe, expect, it } from 'vitest'
import { DEFAULT_IDLE_TIMEOUT_MINUTES, idleTimeoutMs, parseIdleTimeoutMinutes } from './config'

describe('idle timeout configuration', () => {
  it('defaults to 15 minutes', () => {
    expect(DEFAULT_IDLE_TIMEOUT_MINUTES).toBe(15)
    expect(idleTimeoutMs).toBe(15 * 60_000) // VITE_IDLE_TIMEOUT_MINUTES is not set in tests
  })

  it.each([
    [undefined, 15],
    ['', 15],
    ['abc', 15],
    ['0', 15],
    ['-5', 15],
    ['5', 5],
    ['0.5', 0.5],
    ['100000', 720],
  ])('parses %s as %s minutes', (raw, expected) => {
    expect(parseIdleTimeoutMinutes(raw)).toBe(expected)
  })
})
