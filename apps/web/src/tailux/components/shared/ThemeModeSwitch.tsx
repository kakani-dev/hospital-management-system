// Ported from Tailux starter src/app/pages/settings/Sidebar/SidebarPanel/Footer.jsx (the
// System / Light / Dark segmented switch), typed and given accessible names.
import { Radio, RadioGroup } from '@headlessui/react'
import { ComputerDesktopIcon, MoonIcon, SunIcon } from '@heroicons/react/24/outline'
import clsx from 'clsx'
import { Button } from '@tailux/components/ui'
import { useThemeContext } from '../../contexts/theme/context'
import type { ThemeMode } from '../../configs/theme.config'

const options: Array<{ value: ThemeMode; label: string; Icon: typeof SunIcon }> = [
  { value: 'system', label: 'System theme', Icon: ComputerDesktopIcon },
  { value: 'light', label: 'Light theme', Icon: SunIcon },
  { value: 'dark', label: 'Dark theme', Icon: MoonIcon },
]

export function ThemeModeSwitch({ className }: { className?: string }) {
  const { themeMode, setThemeMode } = useThemeContext()

  return (
    <RadioGroup
      value={themeMode}
      onChange={setThemeMode}
      aria-label="Theme"
      data-testid="theme-switch"
      className={clsx(
        'flex w-max rounded-lg bg-gray-200 px-1 py-1 text-gray-600 dark:bg-dark-700 dark:text-dark-200',
        className,
      )}
    >
      {options.map(({ value, label, Icon }) => (
        <Radio
          key={value}
          value={value}
          aria-label={label}
          title={label}
          className={({ checked }: { checked: boolean }) =>
            clsx(
              'flex-1 shrink-0 whitespace-nowrap rounded-lg px-2 py-1 font-medium',
              checked
                ? 'bg-white shadow-sm dark:bg-dark-500 dark:text-dark-100'
                : 'hover:text-gray-800 focus:text-gray-800 dark:hover:text-dark-100 dark:focus:text-dark-100',
            )
          }
          as={Button}
          unstyled
        >
          <Icon className="size-4.5" aria-hidden="true" />
        </Radio>
      ))}
    </RadioGroup>
  )
}
