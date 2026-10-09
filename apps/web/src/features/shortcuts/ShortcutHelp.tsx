import { useEffect, useRef } from 'react'
import { Button } from '../../components/ui/Button'
import { can } from '../../lib/permissions'
import { SHORTCUTS } from './shortcuts'

/** "?" dialog listing the shortcuts available to the current role. */
export function ShortcutHelp({ roles, onClose }: { roles: string[]; onClose: () => void }) {
  const closeRef = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null
    closeRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      opener?.focus?.()
    }
  }, [onClose])
  const available = SHORTCUTS.filter((s) => !s.capability || can(roles, s.capability))
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
      <div role="dialog" aria-modal="true" aria-labelledby="shortcut-help-title" data-testid="shortcut-help" className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
        <h2 id="shortcut-help-title" className="mb-4 text-lg font-semibold">
          Keyboard shortcuts
        </h2>
        <dl className="space-y-2 text-sm">
          {available.map((s) => (
            <div key={s.id} className="flex items-baseline gap-3">
              <dt className="w-16 shrink-0">
                <kbd className="rounded border border-slate-300 bg-slate-50 px-1.5 py-0.5 font-mono text-xs">{s.keys}</kbd>
              </dt>
              <dd>{s.description}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-xs text-slate-600">In a patient search: ↑/↓ to move, Enter to choose, Esc to close or clear.</p>
        <div className="mt-6 flex justify-end">
          <Button ref={closeRef} variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
    </div>
  )
}
