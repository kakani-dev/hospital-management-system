// Ported from Tailux starter src/app/layouts/Sideblock/Sidebar/Menu/Group/MenuItem.jsx (typed;
// i18n and route-loader badges dropped, aria-keyshortcuts added).
import clsx from 'clsx'
import { NavLink } from 'react-router'
import { useBreakpointsContext } from '../../contexts/breakpoint/context'
import { useSidebarContext } from '../../contexts/sidebar/context'
import type { NavItem } from './types'

export function MenuItem({ data }: { data: NavItem }) {
  const { Icon, path, title, end, keys, onPrefetch } = data
  const { lgAndDown } = useBreakpointsContext()
  const { close } = useSidebarContext()

  const handleMenuItemClick = () => {
    if (lgAndDown) close()
  }

  return (
    <li className="relative flex px-3">
      <NavLink
        to={path}
        end={end}
        aria-keyshortcuts={keys}
        onClick={handleMenuItemClick}
        onMouseEnter={onPrefetch}
        onFocus={onPrefetch}
        className={({ isActive }) =>
          clsx(
            'group min-w-0 flex-1 rounded-md px-3 py-2 font-medium outline-hidden transition-colors ease-in-out',
            isActive
              ? 'text-primary-600 dark:text-primary-400'
              : 'text-gray-800 hover:bg-gray-100 hover:text-gray-950 focus:bg-gray-100 focus:text-gray-950 dark:text-dark-200 dark:hover:bg-dark-300/10 dark:hover:text-dark-50 dark:focus:bg-dark-300/10',
          )
        }
      >
        {({ isActive }) => (
          <>
            <div data-menu-active={isActive} className="flex min-w-0 items-center justify-between gap-2 text-xs-plus tracking-wide">
              <div className="flex min-w-0 items-center gap-3">
                {Icon && (
                  <Icon
                    aria-hidden="true"
                    className={clsx('size-5 shrink-0 stroke-[1.5]', !isActive && 'opacity-80 group-hover:opacity-100')}
                  />
                )}
                <span className="truncate">{title}</span>
              </div>
            </div>
            {isActive && (
              <div className="absolute bottom-1 top-1 w-1 bg-primary-600 dark:bg-primary-400 ltr:left-0 ltr:rounded-r-full rtl:right-0 rtl:rounded-l-lg" />
            )}
          </>
        )}
      </NavLink>
    </li>
  )
}
