import { Route, Routes } from 'react-router'
import { useAuth } from './features/auth/AuthProvider'
import { AppShell } from './components/layout/AppShell'
import { LoginPage } from './features/auth/LoginPage'
import { RequireAuth } from './features/auth/RequireAuth'
import { DashboardPage } from './features/dashboard/DashboardPage'
import { PatientListPage } from './features/patients/PatientListPage'
import { RegisterPatientPage } from './features/patients/RegisterPatientPage'
import { PatientDetailPage } from './features/patients/PatientDetailPage'
import { RequireAdmin } from './features/admin/RequireAdmin'
import { BranchesPage } from './features/admin/BranchesPage'
import { MembersPage } from './features/admin/MembersPage'
import { NotFoundPage } from './pages/NotFoundPage'
import { RequireCapability } from './features/auth/RequireCapability'
import { AppointmentCalendarPage } from './features/scheduling/AppointmentCalendarPage'
import { StaffSchedulePage } from './features/scheduling/StaffSchedulePage'

export function App() {
  // Remount every page whenever the query cache is cleared (tenant switch/mismatch, sign-out), so
  // components never keep rendering data from a removed cache entry.
  const { cacheEpoch } = useAuth()
  return (
    <Routes key={cacheEpoch}>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route index element={<DashboardPage />} />
          <Route path="patients" element={<PatientListPage />} />
          <Route path="patients/new" element={<RegisterPatientPage />} />
          <Route path="patients/:patientId" element={<PatientDetailPage />} />
          <Route element={<RequireCapability capability="appointments.view" />}>
            <Route path="appointments" element={<AppointmentCalendarPage />} />
          </Route>
          <Route element={<RequireCapability capability="schedules.view" />}>
            <Route path="schedules" element={<StaffSchedulePage />} />
          </Route>
          <Route path="admin" element={<RequireAdmin />}>
            <Route path="branches" element={<BranchesPage />} />
            <Route path="members" element={<MembersPage />} />
          </Route>
          <Route path="*" element={<NotFoundPage />} />
        </Route>
      </Route>
    </Routes>
  )
}
