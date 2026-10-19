/** Platform timestamps are shown in UTC (labelled): an operator has no hospital zone of their own. */
export const formatUtc = (iso: string | null | undefined) =>
  iso ? `${new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }).format(new Date(iso))} UTC` : '—'

export const statusColor = (status: string) =>
  status === 'active' || status === 'approved' ? 'success' : status === 'pending' ? 'info' : status === 'suspended' ? 'warning' : 'error'
