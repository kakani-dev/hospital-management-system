// Ported from Tailux starter src/app/layouts/Sideblock/Sidebar/{index,Header}.jsx and
// Menu/index.jsx (typed). The navigation comes from the caller (HMS builds it from permissions);
// SimpleBar is replaced by a native scroll area; the Tailux logo by the HMS mark.
import { Portal } from '@headlessui/react'
import { ChevronLeftIcon } from '@heroicons/react/24/outline'
import clsx from 'clsx'
import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { Button } from '@tailux/components/ui'
import { useBreakpointsContext } from '../../contexts/breakpoint/context'
import { useSidebarContext } from '../../contexts/sidebar/context'
import { useThemeContext } from '../../contexts/theme/context'
import { Group } from './Group'
import type { NavGroup } from './types'

function SidebarHeader({ appName }: { appName: string }) {
  const { close } = useSidebarContext()
  return (
    <header className="relative flex h-[61px] shrink-0 items-center justify-between ltr:pl-6 ltr:pr-3 rtl:pl-3 rtl:pr-6">
      <div className="flex items-center justify-start gap-3 pt-3">
        <Link to="/" aria-label={`${appName} home`} className="flex items-center gap-3">
          <span
            aria-hidden="true"
            className="flex size-9 items-center justify-center rounded-lg bg-primary-600 text-lg font-bold text-white dark:bg-primary-500"
          >
            +
          </span>
          <span className="text-lg font-semibold tracking-wide text-gray-800 dark:text-dark-50">{appName}</span>
        </Link>
      </div>
      <div className="pt-5 xl:hidden">
        <Button onClick={close} variant="flat" isIcon className="size-6 rounded-full" aria-label="Close navigation">
          <ChevronLeftIcon className="size-5 rtl:rotate-180" aria-hidden="true" />
        </Button>
      </div>
    </header>
  )
}

export function Sidebar({ navigation, appName, top }: { navigation: NavGroup[]; appName: string; top?: ReactNode }) {
  const { cardSkin } = useThemeContext()
  const { lgAndDown } = useBreakpointsContext()
  const { isExpanded: isSidebarExpanded, close: closeSidebar } = useSidebarContext()

  return (
    <div
      id="primary-sidebar"
      className={clsx(
        'sidebar-panel',
        cardSkin === 'shadow' ? 'shadow-soft dark:shadow-dark-900/60' : 'border-gray-200 dark:border-dark-600/80 ltr:border-r rtl:border-l',
      )}
    >
      <div className={clsx('flex h-full grow flex-col bg-white', cardSkin === 'shadow' ? 'dark:bg-dark-750' : 'dark:bg-dark-900')}>
        <SidebarHeader appName={appName} />
        {top}
        <nav aria-label="Primary" className="custom-scrollbar h-full overflow-x-hidden overflow-y-auto pb-6">
          <div className="space-y-1">
            {navigation.map((group) => (
              <Group key={group.id} data={group} />
            ))}
          </div>
        </nav>
      </div>

      {lgAndDown && isSidebarExpanded && (
        <Portal>
          <div
            onClick={closeSidebar}
            aria-hidden="true"
            className="fixed inset-0 z-20 bg-gray-900/50 backdrop-blur-sm transition-opacity dark:bg-black/40"
          />
        </Portal>
      )}
    </div>
  )
}
