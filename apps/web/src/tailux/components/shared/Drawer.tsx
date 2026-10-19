// Ported from the Tailux demo right drawer (js/demo/src/app/pages/components/drawer/Right.jsx):
// the same Headless UI Dialog + slide-in panel, backdrop and close button, made reusable (title,
// body and footer from the caller) and typed.
import { Dialog, DialogPanel, DialogTitle, Transition, TransitionChild } from '@headlessui/react'
import { XMarkIcon } from '@heroicons/react/24/solid'
import clsx from 'clsx'
import { Fragment, type ReactNode } from 'react'
import { Button } from '@tailux/components/ui'

export function Drawer({
  open,
  onClose,
  title,
  children,
  footer,
  className,
  testId,
  closeLabel = 'Close',
}: {
  open: boolean
  onClose: () => void
  title: ReactNode
  children: ReactNode
  footer?: ReactNode
  className?: string
  testId?: string
  /** Accessible name of the X button (distinct from any Close button in the body). */
  closeLabel?: string
}) {
  return (
    <Transition appear show={open} as={Fragment}>
      <Dialog as="div" className="relative z-100" onClose={onClose}>
        <TransitionChild
          as={Fragment}
          enter="ease-out duration-300"
          enterFrom="opacity-0"
          enterTo="opacity-100"
          leave="ease-in duration-200"
          leaveFrom="opacity-100"
          leaveTo="opacity-0"
        >
          <div className="fixed inset-0 bg-gray-900/50 backdrop-blur-sm transition-opacity dark:bg-black/40" />
        </TransitionChild>

        <TransitionChild
          as={Fragment}
          enter="ease-out transform-gpu transition-transform duration-200"
          enterFrom="translate-x-full"
          enterTo="translate-x-0"
          leave="ease-in transform-gpu transition-transform duration-200"
          leaveFrom="translate-x-0"
          leaveTo="translate-x-full"
        >
          <DialogPanel
            data-testid={testId}
            className={clsx(
              'fixed right-0 top-0 flex h-full w-full max-w-md transform-gpu flex-col bg-white transition-transform duration-200 dark:bg-dark-700',
              className,
            )}
          >
            <div className="flex items-center justify-between border-b border-gray-200 px-4 py-3 dark:border-dark-500 sm:px-5">
              <DialogTitle as="h2" className="text-base font-medium text-gray-800 dark:text-dark-50">
                {title}
              </DialogTitle>
              <Button onClick={onClose} variant="flat" isIcon className="size-7 rounded-full ltr:-mr-1.5" aria-label={closeLabel}>
                <XMarkIcon className="size-4.5" aria-hidden="true" />
              </Button>
            </div>
            <div className="grow overflow-y-auto px-4 py-4 sm:px-5">{children}</div>
            {footer && <div className="border-t border-gray-200 p-4 dark:border-dark-500 sm:px-5">{footer}</div>}
          </DialogPanel>
        </TransitionChild>
      </Dialog>
    </Transition>
  )
}
