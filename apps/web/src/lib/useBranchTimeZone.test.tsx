import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import { App } from '../App'
import { ALPHA, ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const queue = () => json([])
const open = (branch = ALPHA_MAIN, page = 'schedules') =>
  renderWithProviders(<App />, { path: `/${page}?branch=${branch}`, auth: fakeAuthClient({ session: fakeSession() }) })
const zoneLabel = () => screen.findByText(/times in /)

describe('branch → hospital time zone (never the workstation)', () => {
  it('prefers the effective zone from /me over GET /branches', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () =>
        json(meWithRoles(['nurse'], null, { accessibleBranches: [{ id: ALPHA_MAIN, name: 'Alpha Main', timeZone: 'Asia/Dubai' }] })),
      'GET /api/v1/branches': () => json([{ id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true }]),
      'GET /api/v1/queue': queue,
    })
    open()
    expect(await zoneLabel()).toHaveTextContent('times in Asia/Dubai')
    expect(calls.some((c) => c.path === '/api/v1/tenants/current')).toBe(false)
  })

  it('falls back to the hospital zone when the branch has none', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['nurse'], null, { accessibleBranches: [{ id: ALPHA_EAST, name: 'Alpha East' }] })),
      'GET /api/v1/branches': () => json([{ id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: '', isActive: true }]),
      'GET /api/v1/tenants/current': () =>
        json({ id: ALPHA, code: 'alpha', name: 'Demo Alpha Hospital', activeBranchId: null, roles: ['nurse'], timeZone: 'America/New_York' }),
      'GET /api/v1/queue': queue,
    })
    open(ALPHA_EAST)
    expect(await zoneLabel()).toHaveTextContent('times in America/New_York')
    expect(calls.some((c) => c.path === '/api/v1/tenants/current')).toBe(true)
    expect(screen.queryByText(/No time zone is configured/)).not.toBeInTheDocument()
  })

  it('shows an error and loads nothing date-based when no zone is known', async () => {
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meWithRoles(['nurse'], null, { accessibleBranches: [{ id: ALPHA_EAST, name: 'Alpha East' }] })),
      'GET /api/v1/branches': () => json([]),
      'GET /api/v1/queue': queue,
    })
    open(ALPHA_EAST, 'queue')
    expect(await screen.findByText(/No time zone is configured for this branch or hospital/)).toBeInTheDocument()
    expect(calls.some((c) => c.path === '/api/v1/queue')).toBe(false)
  })
})
