import { Link } from 'react-router'

export function NotFoundPage() {
  return (
    <div className="space-y-3">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Page not found</h1>
      <Link className="text-primary-600 dark:text-primary-400 underline" to="/">
        Back to dashboard
      </Link>
    </div>
  )
}
