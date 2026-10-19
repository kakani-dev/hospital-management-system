import type { ReactNode } from 'react'
import { Card as TxCard } from '@tailux/components/ui'

/** Section card: the Tailux Card (theme card skin) with the HMS title/aria-label convention. */
export function Card({ title, children, className = '' }: { title?: string; children: ReactNode; className?: string }) {
  return (
    <TxCard component="section" className={`p-4 sm:p-5 ${className}`} aria-label={title}>
      {title && <h2 className="mb-3 text-base font-medium tracking-wide text-gray-800 dark:text-dark-100">{title}</h2>}
      {children}
    </TxCard>
  )
}
