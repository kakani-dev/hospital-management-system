import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { App } from './App'
import { SessionProvider } from './features/auth/session'

function renderApp(path = '/') {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <SessionProvider>
        <MemoryRouter initialEntries={[path]}>
          <App />
        </MemoryRouter>
      </SessionProvider>
    </QueryClientProvider>,
  )
}

describe('App routing', () => {
  it('redirects unauthenticated users to login', () => {
    renderApp('/patients')
    expect(screen.getByRole('heading', { name: /sign in to hms/i })).toBeInTheDocument()
  })

  it('shows validation errors and then signs in to the dashboard', async () => {
    const user = userEvent.setup()
    renderApp('/login')

    await user.click(screen.getByRole('button', { name: /sign in/i }))
    expect(await screen.findByText(/valid email address/i)).toBeInTheDocument()

    await user.type(screen.getByLabelText(/email/i), 'demo@alpha.example')
    await user.type(screen.getByLabelText(/password/i), 'synthetic-pass')
    await user.click(screen.getByRole('button', { name: /sign in/i }))

    expect(await screen.findByRole('heading', { name: /dashboard/i })).toBeInTheDocument()
    expect(screen.getByTestId('tenant-name')).toHaveTextContent('Demo Alpha Hospital')
  })
})
