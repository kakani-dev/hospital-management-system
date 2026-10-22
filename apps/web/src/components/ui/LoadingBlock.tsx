import { Skeleton } from '@tailux/components/ui'

/** Route and panel placeholder. The Tailux Skeleton (demo `components/ui/Skeleton`) stands in for the row that is coming. */
export function LoadingBlock({ rows = 3, label = 'Loading', className = '' }: { rows?: number; label?: string; className?: string }) {
  return (
    <div role="status" aria-busy="true" aria-label={label} className={`space-y-2 ${className}`}>
      <span className="sr-only">{label}…</span>
      {Array.from({ length: rows }, (_, i) => (
        <Skeleton key={i} className="h-8 w-full rounded" />
      ))}
    </div>
  )
}
