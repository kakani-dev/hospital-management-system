# Sprint 2 web (s2/web)

Coded against `/workspace/SPRINT2-CONTRACT.md` **DB v4 (16:39 IST) + API v2 (16:50 IST)** and the CTO's review of
696ef25. Every route below is in the contract; none is UI-only. The mocked Playwright backend (`tests/playwright/mocked/mock-backend.ts`)
implements the same routes, status codes and `code` values.

## Screens and routes

| Route | Who sees it (UX gate; the API enforces) | API |
|---|---|---|
| `/patients` | REG_READ | `GET /patients`, `POST /patients/search` `{search?, phone?, dateOfBirth?, includeDeleted?}` (admin: "Include deleted" + `POST /patients/{id}/restore`) |
| `/patients/new` | REG_WRITE | `POST /patients/duplicates` at submit (advisory warning: open existing or register anyway), `POST /patients` |
| `/patients/:id` | REG_READ; edit = REG_WRITE @registered branch; delete = tenant_admin / receptionist @branch | `GET`, `PATCH` (merge-patch, never `mrn`), `DELETE` `{reason?}` with confirm dialog |
| `/schedules` | any tenant member | `GET /practitioners`, `GET /schedules?branchId=` (weekly, ISO weekday) |
| `/appointments` | REG_READ; book/cancel = REG_WRITE @branch | `GET /appointments?branchId&from&to&pageSize=100` (instants of branch-local midnight), `GET /practitioners?branchId=` (filter + booking picker), `GET /slots`, `POST /appointments`, `POST /appointments/{id}/cancel` |
| `/reception/check-in` | FRONT_DESK @branch | `POST /appointments/{id}/check-in`, `POST /queue/walk-in` (doctor list from `GET /practitioners?branchId=`) |
| `/queue` | REG_READ + branch access; call in / done = FRONT_DESK or doctor @branch; remove = FRONT_DESK | `GET /queue?branchId&date` (10 s `refetchInterval`), `PATCH /queue/{id}` |

- Branch-scoped screens pick from `/me.accessibleBranches` (`?branch=` in the URL); write buttons use the
  roles held **at that branch** (`rolesAtBranch`), tenant_admin is tenant-wide.
- Dates: "today" and day/week ranges are branch-local (`GET /branches` timezone, workstation zone as fallback),
  via `localToday` / `zonedTimeToInstant` in `lib/dates.ts`. Times render in the branch zone.
- Patient forms (register, edit) check DOB ≤ today **in the zone of the chosen registered branch**, like the API
  (`createPatientSchema(getTimeZone)` + `useBranchZonedResolver`); the date input's `max` follows the branch. The
  search DOB cap is the latest "today" across the user's branches.
- Patient names on calendar, check-in and queue come from the embedded `patient` summary (API v2): no per-row
  `GET /patients/{id}`. `patient: null` (soft-deleted / not readable) shows "Patient unavailable". Only when the
  field is absent (older API) does `usePatientRefs` fall back to cached `GET /patients/{id}`.
- Practitioner pickers use `GET /practitioners?branchId=`. On 400 (older API) they fall back to the tenant-wide
  list filtered by `GET /schedules?branchId=`. Names always resolve from the tenant-wide list.
- Code splitting: calendar, schedules, check-in and queue are `React.lazy` routes; supabase-js and React live in
  vendor chunks (`vite.config.ts` `codeSplitting.groups`). No chunk exceeds 500 kB in configured builds.
- 409 codes mapped to messages: `appointment_overlap` (slot list reloads), `already_checked_in`, `invalid_state`
  (delete with open appointments / check-in not today), `invalid_transition`; 404 on booking (v4: deleted or
  foreign patient/practitioner).

## Resolved (CTO review of 696ef25, contract API v2 16:50 IST)
- Patient summary on AppointmentDto / QueueEntryDto: adopted (was N+1 `GET /patients/{id}`).
- `GET /practitioners?branchId=`: adopted (was a schedule-based filter, now kept only as the 400 fallback).
- DOB "today" in the branch zone: forms now use the selected branch's zone.

## Open questions for Backend and DB
1. **Older API that ignores `branchId`:** the UI can only detect "not supported" from a 400. An API that silently
   ignores the parameter returns the tenant-wide list, which looks valid. Is there a version signal (header or
   `/health` field) we should check, or can we assume every deployed API is v2 or newer?
2. **Branch list for non-admins hides inactive branches.** If a patient is registered at an inactive branch, a
   non-admin's edit form cannot get that branch's zone and falls back to the workstation zone. Should
   `GET /branches` return inactive branches (read-only) to members, or should `PatientDetailDto` carry the zone?
3. `GET /practitioners?branchId=` counts schedules that start in the future, so a practitioner can appear in
   today's booking picker with no slots. Fine for us (the slot list says so); flagging in case it's unintended.
4. Not wired in the UI this sprint: reschedule, no-show, practitioner/schedule admin (POST/PATCH/DELETE),
   `duplicateWarnings` on `PatientCreatedDto` (the pre-check already covers it), and the duplicate check on edit
   (`excludePatientId`).
