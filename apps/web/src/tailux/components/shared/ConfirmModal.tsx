// Ported from Tailux starter src/components/shared/ConfirmModal.jsx (typed). HMS changes: the title
// and body come from the caller, role="alertdialog", initial focus on the safe Cancel action
// (the template focuses the destructive action), and the panel carries a test id.
import { Dialog, DialogPanel, DialogTitle, Description, Transition, TransitionChild } from '@headlessui/react'
import { ExclamationTriangleIcon } from '@heroicons/react/24/outline'
import clsx from 'clsx'
import { useRef, type ReactNode } from 'react'
import { Button, GhostSpinner } from '@tailux/components/ui'

export function ConfirmModal({
  show,
  onClose,
  onOk,
  confirmLoading = false,
  className,
  title,
  children,
  actionText,
  color = 'error',
  testId,
}: {
  show: boolean
  onClose: () => void
  onOk: () => void
  confirmLoading?: boolean
  className?: string
  title: ReactNode
  children: ReactNode
  actionText: ReactNode
  color?: 'error' | 'primary' | 'warning'
  testId?: string
}) {
  const cancelRef = useRef<HTMLButtonElement>(null)

  return (
    <Transition appear show={show}>
      <Dialog
        role="alertdialog"
        initialFocus={cancelRef}
        static={confirmLoading}
        onClose={confirmLoading ? () => {} : onClose}
        className="fixed inset-0 z-100 flex flex-col items-center justify-center overflow-hidden px-4 py-6 sm:px-5"
      >
        <TransitionChild
          as="div"
          enter="ease-out duration-300"
          enterFrom="opacity-0"
          enterTo="opacity-100"
          leave="ease-in duration-200"
          leaveFrom="opacity-100"
          leaveTo="opacity-0"
          className="absolute inset-0 bg-gray-900/50 transition-opacity dark:bg-black/40"
        />
        <TransitionChild
          as={DialogPanel}
          data-testid={testId}
          enter="ease-out duration-300"
          enterFrom="opacity-0"
          enterTo="opacity-100"
          leave="ease-in duration-200"
          leaveFrom="opacity-100"
          leaveTo="opacity-0"
          className={clsx(
            'relative flex w-full max-w-md flex-col overflow-y-auto rounded-lg bg-white px-4 py-6 text-center transition-opacity duration-300 dark:bg-dark-700 sm:px-5',
            className,
          )}
        >
          <ExclamationTriangleIcon aria-hidden="true" className="mx-auto size-20 shrink-0 text-warning" />
          <div className="mt-4">
            <DialogTitle as="h2" className="text-xl text-gray-800 dark:text-dark-100">
              {title}
            </DialogTitle>
            <Description as="div" className="mx-auto mt-2 max-w-sm">
              {children}
            </Description>
            <div className="mt-8 flex justify-center space-x-3">
              <Button ref={cancelRef} onClick={onClose} variant="outlined" className="h-9 min-w-[7rem]" disabled={confirmLoading}>
                Cancel
              </Button>
              <Button
                onClick={onOk}
                color={color}
                // HMS: white on the base error tone is 3.1:1; the darker tone meets WCAG AA (4.5:1).
                className={`h-9 min-w-[7rem] space-x-2 ${color === 'error' ? 'bg-this-darker! hover:bg-this-darker/90!' : ''}`}
                disabled={confirmLoading}
              >
                {confirmLoading && <GhostSpinner variant="soft" className="size-4 border-2" />}
                <span>{actionText}</span>
              </Button>
            </div>
          </div>
        </TransitionChild>
      </Dialog>
    </Transition>
  )
}
