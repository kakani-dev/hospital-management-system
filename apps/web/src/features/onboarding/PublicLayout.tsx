import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { Card } from '@tailux/components/ui'

/** Centered public page (same frame as the sign-in page) for flows that need no hospital context. */
export function PublicLayout({ title, subtitle, children, wide = false }: { title: string; subtitle?: string; children: ReactNode; wide?: boolean }) {
  return (
    <main id="main-content" className="min-h-100vh grid w-full grow grid-cols-1 place-items-center">
      <div className={`w-full ${wide ? 'max-w-2xl' : 'max-w-[26rem]'} p-4 sm:px-5`}>
        <div className="text-center">
          <Link to="/login" aria-label="HMS sign-in page" className="mx-auto flex size-16 items-center justify-center rounded-2xl bg-primary-600 text-4xl font-bold text-white dark:bg-primary-500">
            <span aria-hidden="true">+</span>
          </Link>
          <div className="mt-4">
            <h1 className="text-2xl font-semibold text-gray-600 dark:text-dark-100">{title}</h1>
            {subtitle && <p className="text-gray-500 dark:text-dark-300">{subtitle}</p>}
          </div>
        </div>
        <Card className="mt-5 space-y-4 rounded-lg p-5 lg:p-7">{children}</Card>
        <p className="mt-8 text-center text-xs text-gray-500 dark:text-dark-300">Synthetic demo data only. Not for clinical use.</p>
      </div>
    </main>
  )
}
