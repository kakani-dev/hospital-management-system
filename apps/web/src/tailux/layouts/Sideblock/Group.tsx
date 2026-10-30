// Ported from Tailux starter src/app/layouts/Sideblock/Sidebar/Menu/Group/index.jsx (typed; only
// plain items, no collapsible sub-menus).
import clsx from 'clsx'
import { useId } from 'react'
import { Collapse } from '@tailux/components/ui'
import { useDisclosure } from '@tailux/hooks'
import { useThemeContext } from '../../contexts/theme/context'
import { MenuItem } from './MenuItem'
import type { NavGroup } from './types'

export function Group({ data }: { data: NavGroup }) {
  const [isOpened, { toggle }] = useDisclosure(true)
  const { cardSkin } = useThemeContext()
  const listId = useId()

  return (
    <div className="pt-3" data-testid={`nav-group-${data.id}`}>
      <div className={clsx('sticky top-0 z-10 bg-white px-6', cardSkin === 'bordered' ? 'dark:bg-dark-900' : 'dark:bg-dark-750')}>
        <button
          type="button"
          onClick={toggle}
          aria-expanded={isOpened}
          aria-controls={listId}
          className="mb-2 flex cursor-pointer items-center gap-3 pt-2 text-xs font-medium uppercase tracking-wider text-gray-500 outline-hidden hover:text-gray-900 focus:text-gray-900 dark:text-dark-300 dark:hover:text-dark-50 dark:focus:text-dark-50"
        >
          <span>{data.title}</span>
        </button>
        <div
          className={clsx(
            'pointer-events-none absolute inset-x-0 -bottom-3 h-3 bg-linear-to-b from-white to-transparent',
            cardSkin === 'bordered' ? 'dark:from-dark-900' : 'dark:from-dark-750',
          )}
        ></div>
      </div>
      <Collapse in={isOpened}>
        <ul id={listId} className="flex flex-col space-y-1.5">
          {data.childs.map((item) => (
            <MenuItem key={item.id} data={item} />
          ))}
        </ul>
      </Collapse>
    </div>
  )
}
