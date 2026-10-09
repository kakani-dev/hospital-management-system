import { lazy, Suspense, type ReactNode } from "react";
import { Route, Routes } from "react-router";
import { useAuth } from "./features/auth/AuthProvider";
import { AppShell } from "./components/layout/AppShell";
import { LoginPage } from "./features/auth/LoginPage";
import { RequireAuth } from "./features/auth/RequireAuth";
import { DashboardPage } from "./features/dashboard/DashboardPage";
import { PatientListPage } from "./features/patients/PatientListPage";
import { RegisterPatientPage } from "./features/patients/RegisterPatientPage";
import { PatientDetailPage } from "./features/patients/PatientDetailPage";
import { RequireAdmin } from "./features/admin/RequireAdmin";
import { BranchesPage } from "./features/admin/BranchesPage";
import { MembersPage } from "./features/admin/MembersPage";
import { NotFoundPage } from "./pages/NotFoundPage";
import { RequireCapability } from "./features/auth/RequireCapability";
import { WakingBanner } from "./components/layout/WakingBanner";

// Scheduling and OPD screens are split into their own chunks: most sessions (billing, patient
// registration) never open them, and together they pushed the entry chunk past 500 kB.
const AppointmentCalendarPage = lazy(() =>
  import("./features/scheduling/AppointmentCalendarPage").then((m) => ({
    default: m.AppointmentCalendarPage,
  })),
);
const StaffSchedulePage = lazy(() =>
  import("./features/scheduling/StaffSchedulePage").then((m) => ({
    default: m.StaffSchedulePage,
  })),
);
const CheckInPage = lazy(() =>
  import("./features/opd/CheckInPage").then((m) => ({
    default: m.CheckInPage,
  })),
);
const QueueBoardPage = lazy(() =>
  import("./features/opd/QueueBoardPage").then((m) => ({
    default: m.QueueBoardPage,
  })),
);

function Lazy({ children }: { children: ReactNode }) {
  return (
    <Suspense
      fallback={
        <p role="status" className="p-6 text-sm text-slate-600">
          Loading…
        </p>
      }
    >
      {children}
    </Suspense>
  );
}

export function App() {
  // Remount every page whenever the query cache is cleared (tenant switch/mismatch, sign-out), so
  // components never keep rendering data from a removed cache entry.
  const { cacheEpoch } = useAuth();
  return (
    <>
    <WakingBanner />
    <Routes key={cacheEpoch}>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route index element={<DashboardPage />} />
          <Route path="patients" element={<PatientListPage />} />
          <Route path="patients/new" element={<RegisterPatientPage />} />
          <Route path="patients/:patientId" element={<PatientDetailPage />} />
          <Route element={<RequireCapability capability="appointments.view" />}>
            <Route
              path="appointments"
              element={
                <Lazy>
                  <AppointmentCalendarPage />
                </Lazy>
              }
            />
          </Route>
          <Route element={<RequireCapability capability="schedules.view" />}>
            <Route
              path="schedules"
              element={
                <Lazy>
                  <StaffSchedulePage />
                </Lazy>
              }
            />
          </Route>
          <Route element={<RequireCapability capability="queue.checkIn" />}>
            <Route
              path="reception/check-in"
              element={
                <Lazy>
                  <CheckInPage />
                </Lazy>
              }
            />
          </Route>
          <Route element={<RequireCapability capability="queue.view" />}>
            <Route
              path="queue"
              element={
                <Lazy>
                  <QueueBoardPage />
                </Lazy>
              }
            />
          </Route>
          <Route path="admin" element={<RequireAdmin />}>
            <Route path="branches" element={<BranchesPage />} />
            <Route path="members" element={<MembersPage />} />
          </Route>
          <Route path="*" element={<NotFoundPage />} />
        </Route>
      </Route>
    </Routes>
    </>
  );
}
