import { useCallback, useMemo, useState } from 'react'
import { Outlet, useNavigate } from 'react-router'
import {
  BuildingOffice2Icon,
  CalendarDaysIcon,
  ClipboardDocumentCheckIcon,
  ClockIcon,
  Cog6ToothIcon,
  HomeIcon,
  IdentificationIcon,
  QueueListIcon,
  UserGroupIcon,
  UsersIcon,
  CalendarIcon,
  GlobeAltIcon,
  InboxStackIcon,
} from '@heroicons/react/24/outline'
import { ArrowLeftStartOnRectangleIcon, CommandLineIcon } from '@heroicons/react/24/outline'
import { ShortcutHelp } from '../../features/shortcuts/ShortcutHelp'
import { useReceptionShortcuts } from '../../features/shortcuts/useReceptionShortcuts'
import { useAuth } from '../../features/auth/AuthProvider'
import { TenantSwitcher } from '../../features/tenancy/TenantSwitcher'
import { useCurrentContext } from '../../features/tenancy/useCurrentContext'
import { TenantChangedBanner } from '../../features/tenancy/TenantChangedBanner'
import { ContextErrorBanner } from '../../features/tenancy/ContextErrorBanner'
import { can } from '../../lib/permissions'
import { Sideblock, type NavGroup } from '../../tailux/layouts/Sideblock'
import { ThemeModeSwitch } from '../../tailux/components/shared/ThemeModeSwitch'
import { Avatar, Button } from '@tailux/components/ui'

function initialsSource(email: string | null | undefined) {
  const local = (email ?? '').split('@')[0] ?? ''
  const name = local.replace(/[._-]+/g, ' ').trim()
  return /\w/.test(name) ? name : undefined
}

/**
 * Authenticated shell on the Tailux "Sideblock" layout: fixed sidebar with the permission-filtered
 * primary navigation, sticky header (hospital/branch context, theme, shortcuts, account) and the
 * page column with the cross-cutting banners above the routed page.
 */
export function AppShell() {
  const { email, signOut } = useAuth()
  const { isAdmin, roles, me } = useCurrentContext()
  const isPlatformAdmin = me.data?.isPlatformAdmin === true
  // An operator outside any hospital has no clinical screens (the APIs answer 403 anyway).
  const operatorOnly = isPlatformAdmin && !me.data?.activeTenantId
  const navigate = useNavigate()
  const [helpOpen, setHelpOpen] = useState(false)
  const openHelp = useCallback(() => setHelpOpen(true), [])
  const closeHelp = useCallback(() => setHelpOpen(false), [])
  useReceptionShortcuts({ roles, onHelp: openHelp })

  const navigation = useMemo<NavGroup[]>(() => {
    const clinical: NavGroup = {
      id: 'clinical',
      title: 'Clinical',
      childs: operatorOnly ? [] : [
        { id: 'dashboard', path: '/', title: 'Dashboard', end: true, Icon: HomeIcon },
        { id: 'patients', path: '/patients', title: 'Patients', Icon: UsersIcon, keys: '/' },
        ...(can(roles, 'appointments.view')
          ? [
              {
                id: 'appointments',
                path: '/appointments',
                title: 'Appointments',
                Icon: CalendarDaysIcon,
                keys: can(roles, 'appointments.book') ? 'Alt+K' : undefined,
              },
            ]
          : []),
        ...(can(roles, 'schedules.view') ? [{ id: 'schedules', path: '/schedules', title: 'Schedules', Icon: ClockIcon }] : []),
      ],
    }
    const reception: NavGroup = {
      id: 'reception',
      title: 'Reception',
      childs: [
        ...(can(roles, 'queue.checkIn')
          ? [{ id: 'check-in', path: '/reception/check-in', title: 'Check-in', Icon: ClipboardDocumentCheckIcon, keys: 'Alt+C' }]
          : []),
        ...(can(roles, 'queue.view') ? [{ id: 'queue', path: '/queue', title: 'OPD queue', Icon: QueueListIcon, keys: 'Alt+Q' }] : []),
      ],
    }
    const admin: NavGroup = {
      id: 'admin',
      title: 'Administration',
      childs: isAdmin
        ? [
            { id: 'branches', path: '/admin/branches', title: 'Branches', Icon: BuildingOffice2Icon },
            { id: 'members', path: '/admin/members', title: 'Members', Icon: UserGroupIcon },
            { id: 'practitioners', path: '/admin/practitioners', title: 'Practitioners', Icon: IdentificationIcon },
            { id: 'working-hours', path: '/admin/working-hours', title: 'Working hours', Icon: CalendarIcon },
            { id: 'hospital', path: '/admin/hospital', title: 'Hospital settings', Icon: Cog6ToothIcon },
          ]
        : [],
    }
    // Server-checked flag (identity.is_platform_admin); every /platform endpoint re-checks it.
    const platform: NavGroup = {
      id: 'platform',
      title: 'Platform',
      childs: isPlatformAdmin
        ? [
            { id: 'platform-hospitals', path: '/platform', title: 'Hospitals', Icon: GlobeAltIcon },
            { id: 'platform-requests', path: '/platform/requests', title: 'Hospital requests', Icon: InboxStackIcon },
          ]
        : [],
    }
    return [clinical, reception, admin, platform].filter((g) => g.childs.length > 0)
  }, [roles, isAdmin, isPlatformAdmin, operatorOnly])

  const avatarName = initialsSource(email)

  return (
    <>
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-100 focus:rounded-lg focus:bg-white focus:px-4 focus:py-2 dark:focus:bg-dark-700"
      >
        Skip to main content
      </a>
      <Sideblock
        appName="HMS"
        navigation={navigation}
        headerStart={<TenantSwitcher />}
        headerEnd={
          <>
            <ThemeModeSwitch className="max-sm:hidden" />
            <Button
              variant="flat"
              isIcon
              className="size-9 rounded-full"
              aria-label="Keyboard shortcuts"
              title="Keyboard shortcuts (?)"
              aria-keyshortcuts="?"
              onClick={openHelp}
              data-testid="shortcut-help-button"
            >
              <CommandLineIcon className="size-5" aria-hidden="true" />
            </Button>
            <div className="flex items-center gap-2">
              <Avatar size={8} name={avatarName} initialColor="primary" initialVariant="soft" className="max-sm:hidden" aria-hidden="true" />
              <span className="hidden max-w-48 truncate text-xs-plus text-gray-600 dark:text-dark-200 md:inline" data-testid="user-email">
                {email}
              </span>
            </div>
            <Button
              variant="outlined"
              className="h-8 gap-2 px-3 text-xs-plus"
              onClick={async () => {
                await signOut()
                navigate('/login', { replace: true })
              }}
            >
              <ArrowLeftStartOnRectangleIcon className="size-4" aria-hidden="true" />
              <span>Sign out</span>
            </Button>
          </>
        }
      >
        <div role="note" className="this:warning bg-this-darker/10 px-4 py-1 text-center text-xs text-this-darker dark:bg-this-lighter/10 dark:text-this-lighter">
          Demonstration build — synthetic data only. Not for clinical use.
        </div>
        <TenantChangedBanner />
        <ContextErrorBanner />
        <div className="transition-content w-full px-(--margin-x) pb-8 pt-5 lg:pt-6">
          <Outlet />
        </div>
      </Sideblock>
      {helpOpen && <ShortcutHelp roles={roles} onClose={closeHelp} />}
    </>
  )
}
