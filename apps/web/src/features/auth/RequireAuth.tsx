import { Navigate, Outlet, useLocation } from 'react-router'
import { useAuth } from './AuthProvider'
import { ChangePasswordRequired } from './ChangePasswordRequired'

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
  // An admin set this password (#311): the person must choose their own before using the app.
  // app_metadata is server-owned (users cannot clear it); the API also refuses other calls meanwhile.
  if (session.user.app_metadata?.must_change_password === true || session.user.user_metadata?.needs_password === true) return <ChangePasswordRequired />
  return <Outlet />
}
