import { NavLink, Outlet, useNavigate } from 'react-router'
import { useSession } from '../../features/auth/session'
import { TenantBranchIndicator } from '../../features/tenancy/TenantBranchIndicator'
import { Button } from '../ui/Button'

const navItems = [
  { to: '/', label: 'Dashboard', end: true },
  { to: '/patients', label: 'Patients', end: false },
]

export function AppShell() {
  const { session, signOut } = useSession()
  const navigate = useNavigate()

  return (
    <div className="min-h-screen">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-white focus:px-4 focus:py-2"
      >
        Skip to main content
      </a>
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-4 px-4 py-3">
          <div className="flex items-center gap-3">
            <span aria-hidden="true" className="flex h-8 w-8 items-center justify-center rounded-md bg-brand-700 font-bold text-white">
              +
            </span>
            <span className="text-lg font-semibold">HMS</span>
          </div>
          <TenantBranchIndicator />
          <div className="flex items-center gap-3 text-sm">
            <span className="hidden text-slate-600 sm:inline">{session?.email}</span>
            <Button
              variant="secondary"
              onClick={() => {
                signOut()
                navigate('/login')
              }}
            >
              Sign out
            </Button>
          </div>
        </div>
        <nav aria-label="Primary" className="mx-auto max-w-7xl px-4">
          <ul className="flex gap-1">
            {navItems.map((item) => (
              <li key={item.to}>
                <NavLink
                  to={item.to}
                  end={item.end}
                  className={({ isActive }) =>
                    `inline-block border-b-2 px-3 py-2 text-sm font-medium ${
                      isActive ? 'border-brand-700 text-brand-800' : 'border-transparent text-slate-600 hover:text-slate-900'
                    }`
                  }
                >
                  {item.label}
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>
      </header>
      <div role="note" className="bg-amber-50 px-4 py-1 text-center text-xs text-amber-900">
        Demonstration build — synthetic data only. Not for clinical use.
      </div>
      <main id="main-content" tabIndex={-1} className="mx-auto max-w-7xl px-4 py-6">
        <Outlet />
      </main>
    </div>
  )
}
