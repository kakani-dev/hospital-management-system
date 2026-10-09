import type { ReactNode } from 'react'
import { ConfirmModal } from '@tailux/components/shared/ConfirmModal'

/**
 * Modal confirmation (role="alertdialog") on the Tailux ConfirmModal: focus moves to the safe
 * "Cancel" action, Escape cancels (not while busy), and focus returns to the opener on close.
 */
export function ConfirmDialog({
  open,
  title,
  children,
  confirmLabel,
  busy = false,
  onConfirm,
  onCancel,
}: {
  open: boolean
  title: string
  children: ReactNode
  confirmLabel: string
  busy?: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  return (
    <ConfirmModal
      show={open}
      title={title}
      actionText={busy ? 'Working…' : confirmLabel}
      confirmLoading={busy}
      onOk={onConfirm}
      onClose={onCancel}
      testId="confirm-dialog"
    >
      {children}
    </ConfirmModal>
  )
}
