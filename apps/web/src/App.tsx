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
import { BranchesPage } from "./features/admin/BranchesPage";
import { MembersPage } from "./features/admin/MembersPage";
import { NotFoundPage } from "./pages/NotFoundPage";
import { RequireCapability } from "./features/auth/RequireCapability";
import { WakingBanner } from "./components/layout/WakingBanner";
import { RegisterHospitalPage } from "./features/onboarding/RegisterHospitalPage";
import { InvitePage } from "./features/invitations/InvitePage";
import { RequirePlatformAdmin } from "./features/platform/RequirePlatformAdmin";

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
const PractitionersPage = lazy(() =>
  import("./features/admin/PractitionersPage").then((m) => ({ default: m.PractitionersPage })),
);
const WorkingHoursPage = lazy(() =>
  import("./features/admin/WorkingHoursPage").then((m) => ({ default: m.WorkingHoursPage })),
);
const HospitalSettingsPage = lazy(() =>
  import("./features/admin/HospitalSettingsPage").then((m) => ({ default: m.HospitalSettingsPage })),
);
// Platform console (operators only): its own chunk, hospital staff never load it.
const PlatformHospitalsPage = lazy(() =>
  import("./features/platform/PlatformHospitalsPage").then((m) => ({ default: m.PlatformHospitalsPage })),
);
const PlatformHospitalDetailPage = lazy(() =>
  import("./features/platform/PlatformHospitalDetailPage").then((m) => ({ default: m.PlatformHospitalDetailPage })),
);
const HospitalRequestsPage = lazy(() =>
  import("./features/platform/HospitalRequestsPage").then((m) => ({ default: m.HospitalRequestsPage })),
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
        <p role="status" className="p-6 text-sm text-gray-600 dark:text-dark-200">
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
      <Route path="/register-hospital" element={<RegisterHospitalPage />} />
      <Route path="/invite/:token" element={<InvitePage />} />
      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route index element={<DashboardPage />} />
          <Route element={<RequireCapability capability="patients.view" />}>
            <Route path="patients" element={<PatientListPage />} />
            <Route path="patients/:patientId" element={<PatientDetailPage />} />
          </Route>
          <Route element={<RequireCapability capability="patients.write" />}>
            <Route path="patients/new" element={<RegisterPatientPage />} />
          </Route>
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
          <Route path="admin">
            <Route path="branches" element={<RequireCapability capability="admin.branches"><BranchesPage /></RequireCapability>} />
            <Route path="members" element={<RequireCapability capability="admin.members"><MembersPage /></RequireCapability>} />
            <Route
              path="practitioners"
              element={
                <RequireCapability capability="admin.practitioners">
                  <Lazy>
                    <PractitionersPage />
                  </Lazy>
                </RequireCapability>
              }
            />
            <Route
              path="working-hours"
              element={
                <RequireCapability capability="admin.practitioners">
                  <Lazy>
                    <WorkingHoursPage />
                  </Lazy>
                </RequireCapability>
              }
            />
            <Route
              path="hospital"
              element={
                <RequireCapability capability="admin.settings">
                  <Lazy>
                    <HospitalSettingsPage />
                  </Lazy>
                </RequireCapability>
              }
            />
          </Route>
          <Route path="platform" element={<RequirePlatformAdmin />}>
            <Route
              index
              element={
                <Lazy>
                  <PlatformHospitalsPage />
                </Lazy>
              }
            />
            <Route
              path="hospitals/:tenantId"
              element={
                <Lazy>
                  <PlatformHospitalDetailPage />
                </Lazy>
              }
            />
            <Route
              path="requests"
              element={
                <Lazy>
                  <HospitalRequestsPage />
                </Lazy>
              }
            />
          </Route>
          <Route path="*" element={<NotFoundPage />} />
        </Route>
      </Route>
    </Routes>
    </>
  );
}
