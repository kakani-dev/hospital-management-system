import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, meWithRoles, renderWithProviders, stubFetch } from '../../test/fakes'
import { appointment, branchesResponse, paged, practitionersApi, schedules } from '../../test/schedulingFixtures'
import { isTypingTarget } from './shortcuts'

afterEach(() => vi.unstubAllGlobals())

function setup(roles: string[], path = '/') {
  stubFetch({
    'GET /api/v1/me': () => json(meWithRoles(roles, ALPHA_MAIN)),
    'GET /api/v1/branches': () => json(branchesResponse),
    'GET /api/v1/practitioners': practitionersApi,
    'GET /api/v1/schedules': () => json(schedules),
    'GET /api/v1/appointments': () => json(paged([appointment()])),
    'GET /api/v1/queue': () => json([]),
    'GET /api/v1/patients': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
    'POST /api/v1/patients/search': () => json({ items: [], page: 1, pageSize: 25, totalCount: 0 }),
  })
  const user = userEvent.setup()
  renderWithProviders(<App />, { path, auth: fakeAuthClient({ session: fakeSession() }) })
  return user
}

describe('reception keyboard shortcuts', () => {
  it('Alt+C → check-in, Alt+W → walk-in search focused, Alt+Q → queue, Alt+N → register (MRN focused)', async () => {
    const user = setup(['receptionist'])
    await screen.findByRole('link', { name: 'Check-in' })
    await user.keyboard('{Alt>}c{/Alt}')
    expect(await screen.findByRole('heading', { name: 'Reception check-in' })).toBeInTheDocument()

    await user.keyboard('{Alt>}w{/Alt}')
    await waitFor(() => expect(screen.getByRole('combobox', { name: 'Find walk-in patient' })).toHaveFocus())

    // Alt shortcuts work even while typing in a field
    await user.keyboard('{Alt>}q{/Alt}')
    expect(await screen.findByRole('heading', { name: /OPD queue/ })).toBeInTheDocument()

    await user.keyboard('{Alt>}n{/Alt}')
    await screen.findByRole('form', { name: 'Register patient' })
    await waitFor(() => expect(screen.getByLabelText('MRN')).toHaveFocus())
  })

  it('"/" focuses the patient search (navigating to Patients if needed) but types normally inside fields', async () => {
    const user = setup(['receptionist'])
    await screen.findByRole('link', { name: 'Check-in' })
    await user.keyboard('/')
    const search = await screen.findByLabelText('Search patients')
    await waitFor(() => expect(search).toHaveFocus())
    await user.keyboard('a/b')
    expect(search).toHaveValue('a/b')
  })

  it('Alt+B no longer books (the booking shortcut moved to Alt+K)', async () => {
    const user = setup(['receptionist'])
    await screen.findByRole('link', { name: 'Check-in' })
    await user.keyboard('{Alt>}b{/Alt}')
    expect(screen.queryByRole('form', { name: 'Book appointment' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Appointments' })).toHaveAttribute('aria-keyshortcuts', 'Alt+K')
  })

  it('Alt+K opens the booking panel with the practitioner select focused', async () => {
    const user = setup(['receptionist'])
    await screen.findByRole('link', { name: 'Check-in' })
    await user.keyboard('{Alt>}k{/Alt}')
    const form = await screen.findByRole('form', { name: 'Book appointment' })
    await waitFor(() => expect(within(form).getByLabelText('Practitioner')).toHaveFocus())
    // Already on the page: Alt+K again keeps the one panel and refocuses it
    await user.click(within(form).getByRole('button', { name: 'Close' }))
    expect(screen.queryByRole('form', { name: 'Book appointment' })).not.toBeInTheDocument()
    await user.keyboard('{Alt>}k{/Alt}')
    await waitFor(() => expect(within(screen.getByRole('form', { name: 'Book appointment' })).getByLabelText('Practitioner')).toHaveFocus())
    expect(screen.getAllByRole('form', { name: 'Book appointment' })).toHaveLength(1)
  })

  it('"?" lists only the shortcuts the role may use; Esc closes and focus returns', async () => {
    const user = setup(['doctor'])
    const button = await screen.findByRole('button', { name: 'Keyboard shortcuts' })
    await user.keyboard('?')
    const dialog = await screen.findByRole('dialog', { name: 'Keyboard shortcuts' })
    expect(dialog).toHaveTextContent('Alt+Q')
    expect(dialog).toHaveTextContent('Alt+K') // doctors may book
    expect(dialog).not.toHaveTextContent('Alt+C') // but not check in
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await user.click(button)
    expect(await screen.findByRole('dialog')).toBeInTheDocument()
  })

  it('shortcuts the role lacks do nothing', async () => {
    const user = setup(['doctor'], '/queue')
    expect(await screen.findByRole('heading', { name: /OPD queue/ })).toBeInTheDocument()
    await user.keyboard('{Alt>}c{/Alt}')
    expect(screen.queryByRole('heading', { name: 'Reception check-in' })).not.toBeInTheDocument()
    expect(screen.queryByTestId('forbidden')).not.toBeInTheDocument()
  })

  it('nav links advertise their shortcuts', async () => {
    setup(['receptionist'])
    expect(await screen.findByRole('link', { name: 'Check-in' })).toHaveAttribute('aria-keyshortcuts', 'Alt+C')
    expect(screen.getByRole('link', { name: 'OPD queue' })).toHaveAttribute('aria-keyshortcuts', 'Alt+Q')
    expect(screen.getByRole('link', { name: 'Patients' })).toHaveAttribute('aria-keyshortcuts', '/')
  })

  it('isTypingTarget', () => {
    const input = document.createElement('input')
    const checkbox = Object.assign(document.createElement('input'), { type: 'checkbox' })
    expect(isTypingTarget(input)).toBe(true)
    expect(isTypingTarget(document.createElement('textarea'))).toBe(true)
    expect(isTypingTarget(checkbox)).toBe(false)
    expect(isTypingTarget(document.createElement('button'))).toBe(false)
    expect(isTypingTarget(null)).toBe(false)
  })
})
