// Ported from Tailux starter src/app/layouts/Sideblock/Header/index.jsx (typed). The template's
// search, notifications, right sidebar and language selector are replaced by slots the HMS shell
// fills (hospital/branch switcher on the left, theme, shortcuts and account on the right).
import clsx from 'clsx'
import type { ReactNode } from 'react'
import { SidebarToggleBtn } from '../../components/shared/SidebarToggleBtn'
import { useThemeContext } from '../../contexts/theme/context'

export function Header({ start, end }: { start?: ReactNode; end?: ReactNode }) {
  const { cardSkin } = useThemeContext()

  return (
    <header
      className={clsx(
        'app-header transition-content sticky top-0 z-20 flex min-h-[65px] min-w-0 items-center gap-3 border-b border-gray-200 bg-white/80 px-(--margin-x) py-2 backdrop-blur-sm backdrop-saturate-150 dark:border-dark-600',
        cardSkin === 'bordered' ? 'dark:bg-dark-900/80' : 'dark:bg-dark-700/80',
      )}
    >
      <div className="contents xl:hidden">
        <SidebarToggleBtn />
      </div>
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">{start}</div>
      <div className="flex shrink-0 flex-wrap items-center justify-end gap-2">{end}</div>
    </header>
  )
}
