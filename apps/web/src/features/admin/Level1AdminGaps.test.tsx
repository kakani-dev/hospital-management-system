import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_EAST, ALPHA_MAIN, fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const MAIN = { id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: 'Asia/Kolkata', isActive: true, timezoneOverride: null, isDeleted: false }
const EAST = { id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: 'Asia/Kolkata', isActive: false, timezoneOverride: null, isDeleted: false }
const NURSE = { id: 'm0000000-0000-4000-8000-000000000002', userId: '0b000000-0000-4000-8000-000000000002', email: 'nurse@alpha.example', displayName: null, role: 'nurse', branchId: null, branchName: null, status: 'active' }
const session = () => fakeAuthClient({ session: fakeSession() })

describe('Branches: delete and restore', () => {
  it('asks before deleting, shows the DB reason on 409, and restores from "Show deleted"', async () => {
    let deleted = false
    const calls = stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/tenant': () => json({ id: 'x', name: 'Demo Alpha Hospital', timeZone: 'Asia/Kolkata' }),
      'GET /api/v1/branches': (url) =>
        json(url.searchParams.get('includeDeleted') === 'true' ? [MAIN, { ...EAST, isDeleted: deleted }] : deleted ? [MAIN] : [MAIN, EAST]),
      [`DELETE /api/v1/branches/${ALPHA_MAIN}`]: () => json({ title: 'Conflict', status: 409, code: 'invalid_state', detail: 'branch has open appointments or queue entries' }, 409),
      [`DELETE /api/v1/branches/${ALPHA_EAST}`]: () => {
        deleted = true
        return new Response(null, { status: 204 })
      },
      [`POST /api/v1/branches/${ALPHA_EAST}/restore`]: () => {
        deleted = false
        return new Response(null, { status: 204 })
      },
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/admin/branches', auth: session() })

    await user.click(await screen.findByRole('button', { name: 'Delete Alpha Main' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Delete branch' }))
    expect(await screen.findByText('Could not delete Alpha Main: branch has open appointments or queue entries.')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Delete Alpha East' }))
    await user.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Delete branch' }))
    expect(await screen.findByText(/Alpha East was deleted/)).toBeInTheDocument()
    await waitFor(() => expect(screen.getAllByTestId('branch-row')).toHaveLength(1))

    await user.click(screen.getByLabelText('Show deleted branches'))
    await user.click(await screen.findByRole('button', { name: 'Restore Alpha East' }))
    expect(await screen.findByText('Alpha East was restored as inactive. Activate it to use it again.')).toBeInTheDocument()
    expect(calls.filter((c) => c.method !== 'GET').map((c) => `${c.method} ${c.path}`)).toEqual([
      `DELETE /api/v1/branches/${ALPHA_MAIN}`,
      `DELETE /api/v1/branches/${ALPHA_EAST}`,
      `POST /api/v1/branches/${ALPHA_EAST}/restore`,
    ])
  })
})

describe('Members: invite links, branch scope and removal', () => {
  const routes = (extra: Parameters<typeof stubFetch>[0] = {}) =>
    stubFetch({
      'GET /api/v1/me': () => json(meFor()),
      'GET /api/v1/members': () => json([NURSE]),
      'GET /api/v1/branches': () => json([MAIN, { ...EAST, isActive: true }]),
      'GET /api/v1/members/invite-links': () =>
        json([{ id: 'l1', email: 'old@alpha.example', role: 'doctor', branchId: ALPHA_MAIN, status: 'pending', expiresOn: '2026-10-26T00:00:00Z', createdOn: '2026-10-19T00:00:00Z', claimedOn: null }]),
      ...extra,
    })

  it('creates a single-use invite link for someone without an account and can revoke pending ones', async () => {
    const calls = routes({
      'POST /api/v1/members/invite-links': () => json({ id: 'l2', token: 'ef'.repeat(32), path: `/invite/${'ef'.repeat(32)}`, expiresOn: '2026-10-26T09:00:00Z' }, 201),
      'DELETE /api/v1/members/invite-links/l1': () => new Response(null, { status: 204 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/admin/members', auth: session() })
    const form = within(await screen.findByRole('form', { name: 'Create invite link' }))
    await user.type(form.getByLabelText('Email'), 'new.nurse@alpha.example')
    await user.selectOptions(form.getByLabelText('Role'), 'nurse')
    await user.selectOptions(form.getByLabelText('Branch scope'), 'Alpha East')
    await user.click(form.getByRole('button', { name: 'Create invite link' }))
    expect(await screen.findByTestId('invite-link-url')).toHaveValue(`${window.location.origin}/invite/${'ef'.repeat(32)}`)
    expect(calls.find((c) => c.path === '/api/v1/members/invite-links' && c.method === 'POST')!.body).toEqual({
      email: 'new.nurse@alpha.example',
      role: 'nurse',
      branchId: ALPHA_EAST,
    })
    await user.click(await screen.findByRole('button', { name: 'Revoke invite link for old@alpha.example' }))
    await waitFor(() => expect(calls.some((c) => c.method === 'DELETE' && c.path === '/api/v1/members/invite-links/l1')).toBe(true))
  })

  it('moves a member between branch scopes and removes a member after confirming', async () => {
    const calls = routes({
      [`PATCH /api/v1/members/${NURSE.id}`]: () => json({ ...NURSE, branchId: ALPHA_EAST, branchName: 'Alpha East' }),
      [`DELETE /api/v1/members/${NURSE.id}`]: () => new Response(null, { status: 204 }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/admin/members', auth: session() })
    await user.selectOptions(await screen.findByLabelText('Branch scope for nurse@alpha.example'), 'Alpha East')
    await waitFor(() => expect(calls.find((c) => c.method === 'PATCH')?.body).toEqual({ branchId: ALPHA_EAST }))

    await user.click(screen.getByRole('button', { name: 'Remove nurse@alpha.example' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(calls.some((c) => c.method === 'DELETE')).toBe(false)
    await user.click(within(dialog).getByRole('button', { name: 'Remove member' }))
    expect(await screen.findByText('nurse@alpha.example was removed from this hospital.')).toBeInTheDocument()
  })
})
