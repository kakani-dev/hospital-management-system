// Ported from Tailux starter src/components/shared/SidebarToggleBtn.jsx (typed, labelled).
import clsx from 'clsx'
import { useSidebarContext } from '../../contexts/sidebar/context'

export function SidebarToggleBtn() {
  const { toggle, isExpanded } = useSidebarContext()

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label="Toggle navigation"
      aria-expanded={isExpanded}
      aria-controls="primary-sidebar"
      className={clsx(
        isExpanded && 'active',
        'sidebar-toggle-btn flex size-7 cursor-pointer flex-col justify-center space-y-1.5 text-primary-600 outline-hidden focus:outline-hidden dark:text-primary-400 ltr:ml-0.5 rtl:mr-0.5',
      )}
    >
      <span />
      <span />
      <span />
    </button>
  )
}
