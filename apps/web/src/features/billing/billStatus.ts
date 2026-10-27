/** Display labels for bill.status (bill_status check: draft, finalized, cancelled_draft). */
export const BILL_STATUS_LABELS: Record<string, string> = {
  draft: 'Draft',
  finalized: 'Finalized',
  cancelled_draft: 'Cancelled draft',
}

/** One readable label per status; unknown values are shown as-is with underscores spaced. */
export function billStatusLabel(status: string): string {
  return BILL_STATUS_LABELS[status] ?? status.replace(/_/g, ' ')
}

/** Shown where a bill number goes before the bill is finalized (the status says "Draft" once). */
export const UNNUMBERED_BILL = 'Not numbered'
