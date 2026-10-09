# Sprint 2 web (s2/web)

Coded against `/workspace/SPRINT2-CONTRACT.md` **DB v4 (16:39 IST) + API v1 (16:35 IST)**. Every route below
is in the contract; none is UI-only. The mocked Playwright backend (`tests/playwright/mocked/mock-backend.ts`)
implements the same routes, status codes and `code` values.

## Screens and routes

| Route | Who sees it (UX gate; the API enforces) | API |
|---|---|---|
| `/patients` | REG_READ | `GET /patients`, `POST /patients/search` `{search?, phone?, dateOfBirth?, includeDeleted?}` (admin: "Include deleted" + `POST /patients/{id}/restore`) |
| `/patients/new` | REG_WRITE | `POST /patients/duplicates` at submit (advisory warning: open existing or register anyway), `POST /patients` |
| `/patients/:id` | REG_READ; edit = REG_WRITE @registered branch; delete = tenant_admin / receptionist @branch | `GET`, `PATCH` (merge-patch, never `mrn`), `DELETE` `{reason?}` with confirm dialog |
| `/schedules` | any tenant member | `GET /practitioners`, `GET /schedules?branchId=` (weekly, ISO weekday) |
| `/appointments` | REG_READ; book/cancel = REG_WRITE @branch | `GET /appointments?branchId&from&to&pageSize=100` (instants of branch-local midnight), `GET /slots`, `POST /appointments`, `POST /appointments/{id}/cancel` |
| `/reception/check-in` | FRONT_DESK @branch | `POST /appointments/{id}/check-in`, `POST /queue/walk-in` |
| `/queue` | REG_READ + branch access; call in / done = FRONT_DESK or doctor @branch; remove = FRONT_DESK | `GET /queue?branchId&date` (10 s `refetchInterval`), `PATCH /queue/{id}` |

- Branch-scoped screens pick from `/me.accessibleBranches` (`?branch=` in the URL); write buttons use the
  roles held **at that branch** (`rolesAtBranch`), tenant_admin is tenant-wide.
- Dates: "today" and day/week ranges are branch-local (`GET /branches` timezone, workstation zone as fallback),
  via `localToday` / `zonedTimeToInstant` in `lib/dates.ts`. Times render in the branch zone.
- 409 codes mapped to messages: `appointment_overlap` (slot list reloads), `already_checked_in`, `invalid_state`
  (delete with open appointments / check-in not today), `invalid_transition`; 404 on booking (v4: deleted or
  foreign patient/practitioner).

## Questions / conflicts for Backend and DB
1. `AppointmentDto` and `QueueEntryDto` carry only `patientId`: the calendar, check-in and queue board resolve
   names with one cached `GET /patients/{id}` per patient (N+1). Could the DTOs embed `patientMrn`,
   `patientFirstName`, `patientLastName` (REG_READ already covers them)?
2. `GET /practitioners` has no `branchId` filter; the UI offers practitioners that have a schedule at the branch
   (all active ones when the branch has none). OK, or add `?branchId=`?
3. DOB "today" is validated in the **branch** zone by the API; the registration/edit forms use the workstation
   zone (`localToday()`), which is the same for every branch on the Asia/Kolkata demo data. Should the form use
   the selected branch's zone?
4. Not wired in the UI this sprint: reschedule, no-show, practitioner/schedule admin (POST/PATCH/DELETE),
   `duplicateWarnings` on `PatientCreatedDto` (the pre-check already covers it), and the duplicate check on edit
   (`excludePatientId`).
