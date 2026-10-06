import { Link } from 'react-router'

export function NotFoundPage() {
  return (
    <div className="space-y-3">
      <h1 className="text-2xl font-semibold">Page not found</h1>
      <Link className="text-brand-700 underline" to="/">
        Back to dashboard
      </Link>
    </div>
  )
}
