import { useRef } from 'react'
import { Dialog, DialogPanel, DialogTitle } from '@headlessui/react'
import { Button } from '../../components/ui/Button'
import { can } from '../../lib/permissions'
import { SHORTCUTS } from './shortcuts'

/**
 * "?" dialog listing the shortcuts available to the current role. Headless UI Dialog with the
 * Tailux modal markup (backdrop + panel as in the starter/demo modals): Esc closes, focus is trapped
 * and returns to the opener.
 */
export function ShortcutHelp({ roles, onClose }: { roles: string[]; onClose: () => void }) {
  const closeRef = useRef<HTMLButtonElement>(null)
  const available = SHORTCUTS.filter((s) => !s.capability || can(roles, s.capability))
  return (
    <Dialog
      open
      onClose={onClose}
      initialFocus={closeRef}
      className="fixed inset-0 z-100 flex flex-col items-center justify-center overflow-hidden px-4 py-6 sm:px-5"
    >
      <div aria-hidden="true" className="absolute inset-0 bg-gray-900/50 dark:bg-black/40" />
      <DialogPanel
        data-testid="shortcut-help"
        className="relative w-full max-w-md rounded-lg bg-white px-4 py-6 text-gray-700 dark:bg-dark-700 dark:text-dark-200 sm:px-5"
      >
        <DialogTitle as="h2" className="mb-4 text-lg font-semibold text-gray-800 dark:text-dark-50">
          Keyboard shortcuts
        </DialogTitle>
        <dl className="space-y-2 text-sm">
          {available.map((s) => (
            <div key={s.id} className="flex items-baseline gap-3">
              <dt className="w-16 shrink-0">
                <kbd className="rounded border border-gray-300 bg-gray-50 px-1.5 py-0.5 font-mono text-xs dark:border-dark-450 dark:bg-dark-800">{s.keys}</kbd>
              </dt>
              <dd>{s.description}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-xs text-gray-600 dark:text-dark-200">In a patient search: ↑/↓ to move, Enter to choose, Esc to close or clear.</p>
        <div className="mt-6 flex justify-end">
          <Button ref={closeRef} variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      </DialogPanel>
    </Dialog>
  )
}
