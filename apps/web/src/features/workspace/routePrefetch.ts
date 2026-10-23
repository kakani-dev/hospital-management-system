/**
 * Route chunks, warmed when a nav link is hovered or focused so the next click paints without a
 * wait. The dynamic imports match App.tsx so Vite shares one chunk per page.
 */
const loaders: Record<string, () => Promise<unknown>> = {
  '/': () => import('../dashboard/DashboardPage'),
  '/patients': () => import('../patients/PatientListPage'),
  '/patients/new': () => import('../patients/RegisterPatientPage'),
  '/appointments': () => import('../scheduling/AppointmentCalendarPage'),
  '/my-day': () => import('../scheduling/MyDayPage'),
  '/schedules': () => import('../scheduling/StaffSchedulePage'),
  '/reception/check-in': () => import('../opd/CheckInPage'),
  '/queue': () => import('../opd/QueueBoardPage'),
  '/billing/approvals': () => import('../billing/ApprovalsPage'),
  '/billing/day-end': () => import('../billing/DayEndPage'),
  '/stock': () => import('../stock/StockPage'),
  '/admin/desk': () => import('../admin/AdminDeskPage'),
  '/admin/branches': () => import('../admin/BranchesPage'),
  '/admin/members': () => import('../admin/MembersPage'),
  '/admin/practitioners': () => import('../admin/PractitionersPage'),
  '/admin/working-hours': () => import('../admin/WorkingHoursPage'),
  '/admin/hospital': () => import('../admin/HospitalSettingsPage'),
  '/admin/price-list': () => import('../admin/PriceListPage'),
  '/platform': () => import('../platform/PlatformHospitalsPage'),
  '/platform/requests': () => import('../platform/HospitalRequestsPage'),
}

const started = new Set<string>()

export function prefetchRoute(path: string) {
  const load = loaders[path]
  if (!load || started.has(path)) return
  started.add(path)
  void load()
}
