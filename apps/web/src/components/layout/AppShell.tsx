import { useCallback, useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router'
import { ShortcutHelp } from '../../features/shortcuts/ShortcutHelp'
import { useReceptionShortcuts } from '../../features/shortcuts/useReceptionShortcuts'
import { useAuth } from '../../features/auth/AuthProvider'
import { TenantSwitcher } from '../../features/tenancy/TenantSwitcher'
import { useCurrentContext } from '../../features/tenancy/useCurrentContext'
import { TenantChangedBanner } from '../../features/tenancy/TenantChangedBanner'
import { ContextErrorBanner } from '../../features/tenancy/ContextErrorBanner'
import { Button } from '../ui/Button'
import { can } from '../../lib/permissions'

export function AppShell() {
  const { email, signOut } = useAuth()
  const { isAdmin, roles } = useCurrentContext()
  const navigate = useNavigate()
  const [helpOpen, setHelpOpen] = useState(false)
  const openHelp = useCallback(() => setHelpOpen(true), [])
  const closeHelp = useCallback(() => setHelpOpen(false), [])
  useReceptionShortcuts({ roles, onHelp: openHelp })

  const navItems: { to: string; label: string; end: boolean; keys?: string }[] = [
    { to: '/', label: 'Dashboard', end: true },
    { to: '/patients', label: 'Patients', end: false, keys: '/' },
    ...(can(roles, 'appointments.view') ? [{ to: '/appointments', label: 'Appointments', end: false, keys: can(roles, 'appointments.book') ? 'Alt+B' : undefined }] : []),
    ...(can(roles, 'schedules.view') ? [{ to: '/schedules', label: 'Schedules', end: false }] : []),
    ...(can(roles, 'queue.checkIn') ? [{ to: '/reception/check-in', label: 'Check-in', end: false, keys: 'Alt+C' }] : []),
    ...(can(roles, 'queue.view') ? [{ to: '/queue', label: 'OPD queue', end: false, keys: 'Alt+Q' }] : []),
    ...(isAdmin
      ? [
          { to: '/admin/branches', label: 'Branches', end: false },
          { to: '/admin/members', label: 'Members', end: false },
        ]
      : []),
  ]

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
          <TenantSwitcher />
          <div className="flex items-center gap-3 text-sm">
            <span className="hidden text-slate-600 sm:inline" data-testid="user-email">
              {email}
            </span>
            <Button variant="ghost" aria-keyshortcuts="?" onClick={openHelp} data-testid="shortcut-help-button">
              Keyboard shortcuts
            </Button>
            <Button
              variant="secondary"
              onClick={async () => {
                await signOut()
                navigate('/login', { replace: true })
              }}
            >
              Sign out
            </Button>
          </div>
        </div>
        <nav aria-label="Primary" className="mx-auto max-w-7xl px-4">
          <ul className="flex flex-wrap gap-1">
            {navItems.map((item) => (
              <li key={item.to}>
                <NavLink
                  to={item.to}
                  end={item.end}
                  aria-keyshortcuts={item.keys}
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
      <TenantChangedBanner />
      <ContextErrorBanner />
      <main id="main-content" tabIndex={-1} className="mx-auto max-w-7xl px-4 py-6">
        <Outlet />
      </main>
      {helpOpen && <ShortcutHelp roles={roles} onClose={closeHelp} />}
    </div>
  )
}
