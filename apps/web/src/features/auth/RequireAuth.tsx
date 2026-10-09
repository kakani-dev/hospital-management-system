import { Navigate, Outlet, useLocation } from 'react-router'
import { useAuth } from './AuthProvider'

export function RequireAuth() {
  const { session, loading } = useAuth()
  const location = useLocation()
  if (loading) {
    return (
      <p role="status" className="p-8 text-center text-gray-600 dark:text-dark-200">
        Loading session…
      </p>
    )
  }
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  return <Outlet />
}
