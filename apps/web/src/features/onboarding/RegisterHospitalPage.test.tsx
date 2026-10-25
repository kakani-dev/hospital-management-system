import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { App } from '../../App'
import { fakeAuthClient, json, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

async function fill(user: ReturnType<typeof userEvent.setup>) {
  await user.type(await screen.findByLabelText('Hospital name'), 'Synthetic Lotus Clinic')
  const zone = screen.getByLabelText('Hospital time zone')
  await user.clear(zone)
  await user.type(zone, 'Asia/Kolkata')
  await user.type(screen.getByLabelText('City'), 'Pune')
  await user.type(screen.getByLabelText('Your name'), 'Asha Synthetic')
  await user.type(screen.getByLabelText('Work email'), 'asha@lotus.example')
  await user.type(screen.getByLabelText('Phone'), '+91 20 5550 1234')
}

describe('Register your hospital (public)', () => {
  it('is reachable without signing in, posts no tenant id or token, and only promises a review', async () => {
    const calls = stubFetch({ 'POST /api/v1/public/hospital-signups': () => json({ message: 'Thank you. If the details are valid we will review your request.' }, 202) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/register-hospital', auth: fakeAuthClient() })
    await fill(user)
    await user.click(screen.getByRole('button', { name: 'Send request' }))
    expect(await screen.findByRole('heading', { name: 'Request received' })).toBeInTheDocument()
    expect(screen.getByText(/Nothing is set up yet/)).toBeInTheDocument()
    const post = calls.find((c) => c.method === 'POST')!
    expect(post.body).toEqual({
      hospitalName: 'Synthetic Lotus Clinic',
      timeZone: 'Asia/Kolkata',
      contactName: 'Asha Synthetic',
      contactEmail: 'asha@lotus.example',
      phone: '+91 20 5550 1234',
      city: 'Pune',
      website: '',
    })
    expect(post.headers.get('Authorization')).toBeNull()
    expect(post.headers.get('X-Tenant-Id')).toBeNull()
  })

  it('accepts only listed zones and validates the phone before posting', async () => {
    const calls = stubFetch({})
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/register-hospital', auth: fakeAuthClient() })
    const zone = await screen.findByLabelText('Hospital time zone')
    const before = (zone as HTMLInputElement).value
    await user.type(zone, 'Mars/Olympus')
    expect(screen.getByText('No time zone matches “Mars/Olympus”.')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Phone'), 'call me')
    expect(zone).toHaveValue(before)
    await user.click(screen.getByRole('button', { name: 'Send request' }))
    expect(await screen.findByText(/7-20 digits/)).toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
  })

  it('shows a registered-email message and does not claim the request was received', async () => {
    stubFetch({
      'POST /api/v1/public/hospital-signups': () =>
        json(
          {
            title: 'Already registered',
            status: 409,
            code: 'email_registered',
            detail: 'This email is already registered. Please sign in or contact support.',
          },
          409,
        ),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/register-hospital', auth: fakeAuthClient() })
    await fill(user)
    await user.click(screen.getByRole('button', { name: 'Send request' }))
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('This email is already registered. Please sign in or contact support.')
    expect(alert).not.toHaveTextContent('Synthetic Lotus')
    expect(screen.queryByRole('heading', { name: 'Request received' })).not.toBeInTheDocument()
  })

  it('explains a 429 rate limit', async () => {
    stubFetch({ 'POST /api/v1/public/hospital-signups': () => json({ title: 'Too many', status: 429, code: 'rate_limited' }, 429) })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/register-hospital', auth: fakeAuthClient() })
    await fill(user)
    await user.click(screen.getByRole('button', { name: 'Send request' }))
    await waitFor(() => expect(screen.getByText(/Too many registrations/)).toBeInTheDocument())
  })

  it('is linked from the sign-in page', async () => {
    stubFetch({})
    renderWithProviders(<App />, { path: '/login', auth: fakeAuthClient() })
    expect(await screen.findByRole('link', { name: 'Register your hospital' })).toHaveAttribute('href', '/register-hospital')
  })
})
