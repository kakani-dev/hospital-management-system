import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { fakeAuthClient, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const TOKEN = 'cd'.repeat(32)
const exchangePath = `POST /api/v1/public/password-resets/${TOKEN}/sign-in`

describe('Password reset link page (#309)', () => {
  it('does not use the link until Continue, then asks for a new password and opens the app', async () => {
    const calls = stubFetch({
      [exchangePath]: () => json({ tokenHash: 'hash-1', verificationType: 'magiclink' }),
      'GET /api/v1/me': () => json(meFor()),
    })
    const auth = fakeAuthClient()
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/reset-password/${TOKEN}`, auth })
    const continueButton = await screen.findByTestId('reset-password-continue')
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
    await user.click(continueButton)
    expect(await screen.findByTestId('reset-password-form')).toBeInTheDocument()
    await user.type(screen.getByLabelText('New password'), 'short')
    await user.click(screen.getByTestId('reset-password-save'))
    expect(await screen.findByText('Password must be at least 8 characters.')).toBeInTheDocument()
    await user.clear(screen.getByLabelText('New password'))
    await user.type(screen.getByLabelText('New password'), 'a-new-synthetic-pass')
    await user.click(screen.getByTestId('reset-password-save'))
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument()
    expect(calls.filter((c) => c.path.endsWith('/sign-in'))).toHaveLength(1)
  })

  it('explains a used or expired link', async () => {
    stubFetch({ [exchangePath]: () => json({ title: 'Not Found', status: 404 }, 404) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: `/reset-password/${TOKEN}`, auth: fakeAuthClient() })
    await user.click(await screen.findByTestId('reset-password-continue'))
    expect(await screen.findByText(/already used or has expired/)).toBeInTheDocument()
    expect(screen.queryByTestId('reset-password-form')).not.toBeInTheDocument()
  })
})
