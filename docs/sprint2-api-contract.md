## API (Backend)
<!-- BEGIN API (Backend) — owned by Backend (.NET), branch s2/backend. Do not edit other sections from here. -->
Owner: Backend. Version **API v2, 2026-10-09 16:50 IST** (v4 status codes + embedded `patient` + `GET /practitioners?branchId=`), implemented on `s2/backend` against DB contract **v4** (`s2/db` @ 6d13c64, D1–D11) and integration-tested on a scratch Postgres 17. Every route below is implemented.

### A.0 Conventions (unchanged from Sprint 1)
- Base `/api/v1`, JSON camelCase. `date` = `YYYY-MM-DD`; `time` = `HH:mm` (branch-local wall clock); `instant` = ISO-8601 with offset (responses are UTC `…Z`).
- Auth: `Authorization: Bearer <Supabase JWT>`. Tenant comes only from the validated token / stored server context. A `tenantId` in any body or query is ignored (never accepted).
- Every authenticated response with a resolved tenant has `X-Hms-Tenant: <uuid>` (CORS-exposed). Compare it with the tenant you display; reset state on mismatch.
- Reads: tenant-wide for the listed roles (queue board: branch-scoped, D10). Writes: role **at the row's branch** (`HasRoleAtBranch`); `tenant_admin` is tenant-wide.
- **404-not-403 (v4):** another tenant's id (patient, practitioner, appointment, queue entry, schedule **or branch** passed in a body/query), a soft-deleted patient, or an unknown id → **404** `not_found` (indistinguishable). A **same-tenant** branch outside the caller's scope, or a role that isn't allowed → **403** `forbidden`. When the API rejects a branch itself it checks `identity.branches` (RLS-visible) to pick 404 vs 403, so it answers like the DB.
- Paged shape: `Paged<T> = { items: T[], page: int, pageSize: int, totalCount: int }`; `pageSize` 1..100 (default 25), `page` ≥ 1.
- MRN: `^[A-Za-z0-9-]{1,32}$`, stored UPPER-case, unique per tenant case-insensitively, stays reserved after soft delete (D1). Phone ≤ 32, email ≤ 254 (must contain `@`). Names 1..100. DOB 1900-01-01..today **in the branch time zone**.

### A.1 Error shape (RFC 7807) and DB → HTTP mapping
```ts
ProblemDetails   { type: string, title: string, status: int, detail?: string, code?: string, traceId?: string }
ValidationProblem{ type, title: "One or more validation errors occurred.", status: 400, errors: { [field: string]: string[] } }
```
| Status | When | `code` |
|---|---|---|
| 400 | request validation (field errors in `errors`); SQLSTATE `22023`; `23514` that is NOT `invalid_transition:` (e.g. `practitioner_inactive`); `23503` (FK backstop only — v4 raises `P0002` for foreign/deleted refs first) | `invalid_parameter`, `check_violation`, `invalid_reference` |
| 401 | no / invalid / expired token (empty body) | — |
| 403 | role not allowed, same-tenant branch not allowed, SQLSTATE `42501` | `forbidden` |
| 404 | not found / other tenant (any id, incl. branch) / soft-deleted, SQLSTATE `P0002` | `not_found` |
| 409 | `23505` unique, `23P01` overlap, `23514 invalid_transition:*`, `55000` wrong state | `duplicate_mrn`, `already_checked_in`, `schedule_overlap`, `appointment_overlap`, `invalid_transition`, `invalid_state` |
| 429 | rate limited | — |

### A.2 Role shorthand (same as DB §0)
REG_READ = tenant_admin, doctor, nurse, receptionist, billing · REG_WRITE = tenant_admin, doctor, nurse, receptionist · FRONT_DESK = tenant_admin, receptionist, nurse · ADMIN = tenant_admin. "@branch" = the role must be held at the row's branch.

---
### A.3 Patients (2.1)
```ts
PatientSummaryDto { id: uuid, mrn: string, firstName: string, lastName: string, dateOfBirth: date|null,
                    sex: "female"|"male"|"other"|"unknown", registeredBranchId: uuid, phone: string|null,
                    deletedAt: instant|null /* only ever non-null for admins with includeDeleted */ }
PatientDetailDto  = PatientSummaryDto & { email: string|null, createdAt: instant, updatedAt: instant }
DuplicateCandidateDto { id: uuid, mrn, firstName, lastName, dateOfBirth: date|null, phone: string|null,
                        registeredBranchId: uuid, matchReasons: ("name_dob"|"phone")[] }
PatientCreatedDto = PatientDetailDto & { duplicateWarnings: DuplicateCandidateDto[] }   // [] when none; advisory only (D3)

CreatePatientRequest { mrn, firstName, lastName, dateOfBirth?: date, sex?, registeredBranchId: uuid, phone?, email? }
UpdatePatientRequest { firstName?, lastName?, dateOfBirth?: date|null, sex?, phone?: string|null, email?: string|null, registeredBranchId?: uuid }
   // merge-patch: ABSENT = unchanged, explicit null clears dateOfBirth/phone/email. firstName/lastName/sex/registeredBranchId not nullable.
   // "mrn" is immutable (sending a different value → 400 errors.mrn). Unknown properties → 400.
PatientSearchRequest { search?: string /* MRN/first/last contains, ci, ≤100 */, phone?: string /* exact match on DB normalize_phone (last 10 digits, ≥7 digits else 400) */,
                       dateOfBirth?: date /* exact */, includeDeleted?: boolean /* ADMIN only, else 403 */, page?, pageSize? }   // filters AND-ed
DuplicateCheckRequest { firstName?: string, lastName?: string, dateOfBirth?: date, phone?: string, excludePatientId?: uuid }
DeletePatientRequest  { reason?: string /* ≤ 500 */ }    // optional body on DELETE
```
| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| GET | `/patients?page=&pageSize=` | REG_READ | 200 `Paged<PatientSummaryDto>` (deleted excluded) | 400 if `?search=` used |
| POST | `/patients/search` | REG_READ | 200 `Paged<PatientSummaryDto>` | 400, 403 (`includeDeleted` by non-admin) |
| POST | `/patients/duplicates` | REG_WRITE (any branch) | 200 `{ candidates: DuplicateCandidateDto[] }` (≤ 20, both-reasons first) | 400, 403 (no registry write / read — DB `42501`, v4; was an empty list) |
| GET | `/patients/{id}` | REG_READ | 200 `PatientDetailDto` | 404 (incl. deleted; admins too — use search `includeDeleted`) |
| POST | `/patients` | REG_WRITE @registeredBranchId | **201** `PatientCreatedDto`, `Location` | 400, 403 (same-tenant branch without a write role), **404** (`registeredBranchId` of another tenant / unknown; was 403 in Sprint 1, CTO 16:49), 409 `duplicate_mrn` |
| PATCH | `/patients/{id}` | REG_WRITE @current branch (and @new branch if `registeredBranchId` changes) | 200 `PatientDetailDto` | 400, 403, 404 (incl. moving to another tenant's branch) |
| DELETE | `/patients/{id}` | tenant_admin, or receptionist @patient's branch (D1) | **204** (soft delete via `patient.soft_delete_patient`, reason audited) | 400 reason > 500, 403 (same tenant, wrong role/branch), 404 (foreign/unknown/already deleted), 409 `invalid_state` (open appointments/queue, D2) |
| POST | `/patients/{id}/restore` | ADMIN | **204** | 403 (same-tenant non-admin), 404 (foreign/unknown/not deleted) |

---
### A.4 Practitioners, schedules, slots (2.2)
```ts
PractitionerDto { id: uuid, userId: uuid|null, displayName: string, specialty: string|null, isActive: boolean }
CreatePractitionerRequest { displayName: string /* 1..120 */, specialty?: string /* ≤120 */, userId?: uuid }
UpdatePractitionerRequest { displayName?, specialty?: string /* "" clears */, userId?: uuid, unlinkUser?: boolean /* true clears userId */, isActive?: boolean }   // absent/null = unchanged

ScheduleDto { id: uuid, practitionerId: uuid, branchId: uuid, weekday: 1..7 /* ISO, 1 = Mon */, startTime: time, endTime: time,
              slotMinutes: int /* 5..240 */, validFrom: date, validTo: date|null, isActive: boolean }
CreateScheduleRequest { practitionerId, branchId, weekday, startTime, endTime, slotMinutes?: int /* default 15 */, validFrom?: date /* default branch today */, validTo?: date }
UpdateScheduleRequest { weekday?, startTime?, endTime?, slotMinutes?, validFrom?, validTo?: date, clearValidTo?: boolean, isActive? }   // absent/null = unchanged; practitioner/branch immutable

SlotDto { practitionerId: uuid, branchId: uuid, startsAt: instant, endsAt: instant }    // only FREE, future slots (DB available_slots)
```
| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| GET | `/practitioners?activeOnly=true&branchId=` | any tenant member | 200 `PractitionerDto[]` (by displayName). **v2:** with `branchId`, only practitioners that have an **active schedule at that branch** (`isActive` and `validTo` null or ≥ the branch-local today; schedules starting in the future count). Any branch of the caller's tenant is allowed (schedules are tenant-wide). `activeOnly` (default true) still applies. | 404 (`branchId` of another tenant / unknown) |
| POST | `/practitioners` | ADMIN | 201 `PractitionerDto` | 400, 403, 409 (user already linked) |
| PATCH | `/practitioners/{id}` | ADMIN | 200 `PractitionerDto` | 400, 403, 404, 409 |
| GET | `/schedules?branchId=&practitionerId=` | any tenant member | 200 `ScheduleDto[]` | — |
| POST | `/schedules` | ADMIN (@branch) | 201 `ScheduleDto` | 400 (start ≥ end, bad weekday…), 403 (same-tenant branch), 404 (foreign branch or practitioner, v4), 409 `schedule_overlap` |
| PATCH | `/schedules/{id}` | ADMIN | 200 `ScheduleDto` | 400, 403, 404, 409 `schedule_overlap` |
| DELETE | `/schedules/{id}` | ADMIN | 204 | 403, 404 |
| GET | `/slots?branchId=&from=&to=&practitionerId=` | REG_READ **and** branch access | 200 `SlotDto[]` (`from`/`to` branch-local dates, inclusive, ≤ 31 days) | 400, 403 (same-tenant branch outside scope), 404 (foreign branch or foreign `practitionerId`, v4) |

### A.5 Appointments (2.2)
```ts
AppointmentStatus = "booked"|"checked_in"|"in_consultation"|"completed"|"cancelled"|"no_show"
AppointmentDto { id: uuid, branchId: uuid, practitionerId: uuid, patientId: uuid, startsAt: instant, endsAt: instant,
                 status: AppointmentStatus, reason: string|null, cancelReason: string|null,
                 checkedInAt: instant|null, startedAt: instant|null, completedAt: instant|null, cancelledAt: instant|null,
                 createdAt: instant, updatedAt: instant,
                 patient: PatientRef|null /* v2 */ }
PatientRef { id: uuid, mrn: string, firstName: string, lastName: string }   // v2, see "Embedded patient" below
CreateAppointmentRequest     { branchId, practitionerId, patientId, startsAt: instant, endsAt: instant /* > startsAt, ≤ 8 h */, reason?: string /* ≤500 */ }
RescheduleAppointmentRequest { startsAt: instant, endsAt: instant, practitionerId?: uuid }      // only while booked
CancelAppointmentRequest     { reason?: string /* ≤500 */ }
AppointmentSearch (query)    branchId?, practitionerId?, patientId?, date?: date (branch-local; needs branchId) | from?: instant & to?: instant, status?, page?, pageSize?
```
| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| GET | `/appointments?…` | REG_READ (tenant-wide) | 200 `Paged<AppointmentDto>` by `startsAt` | 400, 403 |
| GET | `/appointments/{id}` | REG_READ | 200 `AppointmentDto` | 404 |
| POST | `/appointments` | REG_WRITE @branchId | **201** `AppointmentDto` (`booked`), `Location` | 400 (validation; inactive practitioner → `check_violation`), 403 (same-tenant branch), **404** (foreign branch, foreign/unknown practitioner, foreign or soft-deleted patient — v4, was 400), **409 `appointment_overlap`** |
| POST | `/appointments/{id}/reschedule` | REG_WRITE @its branch | 200 `AppointmentDto` | 400, 403, 404 (incl. foreign `practitionerId`), 409 `appointment_overlap` / `invalid_transition` (not booked) |
| POST | `/appointments/{id}/cancel` | REG_WRITE @its branch | 200 `AppointmentDto` (`cancelled`); a `checked_in` appointment's queue entry is cancelled too (DB trigger, PR #2 review MAJ-1) | 403, 404, 409 `invalid_transition` |
| POST | `/appointments/{id}/no-show` | REG_WRITE @its branch | 200 `AppointmentDto` (`no_show`) | 403, 404, 409 `invalid_transition` (before start / not booked) |

**Embedded patient (v2).** Every `AppointmentDto` and `QueueEntryDto` (list, detail, create/book, reschedule/cancel/no-show, check-in / walk-in `entry`, queue PATCH) carries `patient: { id, mrn, firstName, lastName }`. It is loaded in the **same SQL statement** (LEFT JOIN on `patient.patients`; no per-row lookups) under the caller's RLS, so it only appears for patients the caller can already read through `GET /patients/{id}`. `patient` is **null** when the patient is soft-deleted or not readable; `patientId` is always present. No extra fields (DOB, phone, email) are embedded.

Overlap: same practitioner, half-open `[startsAt, endsAt)`, blocking statuses booked/checked_in/in_consultation/completed. Back-to-back is fine. Enforced by DB `23P01` → 409.

### A.6 Check-in & OPD queue (2.3)
```ts
QueueStatus = "waiting"|"in_consultation"|"done"|"cancelled"
QueueEntryDto { id: uuid, branchId: uuid, queueDate: date /* branch-local */, tokenNo: int, patientId: uuid,
                appointmentId: uuid|null, practitionerId: uuid|null, status: QueueStatus,
                checkedInAt: instant, calledAt: instant|null, completedAt: instant|null, cancelledAt: instant|null,
                patient: PatientRef|null /* v2 */ }
CheckInResultDto { queueEntryId: uuid, tokenNo: int, queueDate: date, entry: QueueEntryDto }
WalkInRequest { branchId: uuid, patientId: uuid, practitionerId?: uuid }
UpdateQueueStatusRequest { status: "in_consultation"|"done"|"cancelled" }
```
| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| POST | `/appointments/{id}/check-in` | FRONT_DESK @appointment's branch | **201** `CheckInResultDto` (appointment → `checked_in`) | 403, 404 (foreign/unknown appointment), 409 `already_checked_in` / `invalid_transition` / `invalid_state` (not today) |
| POST | `/queue/walk-in` | FRONT_DESK @branchId | **201** `CheckInResultDto` | 400, 403 (same-tenant branch / role), 404 (foreign branch, foreign/deleted patient, foreign/inactive practitioner), 409 `already_checked_in` (patient already waiting/in consultation today, D11) |
| GET | `/queue?branchId=&date=&status=` | REG_READ **and** branch access | 200 `QueueEntryDto[]` by `tokenNo` (`date` default = branch today) | 400, 403 (same-tenant branch not accessible), 404 (foreign branch) |
| PATCH | `/queue/{id}` | FRONT_DESK @branch; doctor @branch for `in_consultation`/`done` | 200 `QueueEntryDto` (linked appointment follows) | 400, 403 (same-tenant entry at a branch outside scope, or role — DB `42501`, v4), 404 (foreign/unknown), 409 `invalid_transition` |

### A.7 Outbox (2.4, no HTTP routes)
- Events are written by **DB triggers only** (D8) in the same transaction as the appointment/queue change; the API never inserts into `messaging.outbox`. Every API write runs in one transaction (`WithDbTransaction`), so a rolled-back request leaves no event.
- `OutboxDispatcher` (BackgroundService in the gateway): per batch it opens a transaction, `SET LOCAL ROLE hms_dispatcher`, calls `messaging.claim_outbox(worker, batch, lease)` (FOR UPDATE SKIP LOCKED), publishes through `IOutboxPublisher`, then `complete_outbox` / `fail_outbox` (back-off). At-least-once; consumers dedupe on `eventId`. Config `Outbox:Dispatcher:Enabled` (default **false** until the DB migration is deployed), `BatchSize` (50), `PollIntervalSeconds` (5), `LeaseSeconds` (30), `RetryBaseSeconds` (30, doubles per attempt, cap 1 h), `DedupCapacity` (10 000 recently published `eventId`s skipped on re-claim). S2 publisher = structured log of `eventId/eventType/aggregateId` only (no payload, no PHI).

### A.8 Backend notes / assumptions
- Patient soft delete, restore, duplicates, check-in, walk-in and queue status changes go through the DB RPCs (§1.3, §1.5, §3.3, D11); PATCH/create of patients, practitioners, schedules and appointments use EF under RLS.
- Walk-in uses D11 `appointment.check_in_walk_in(branch, patient, practitioner?)`. A second active queue entry for the same patient/branch/day (`23505`) → 409 `already_checked_in` on both check-in paths.
- Q6: the API does not validate that `practitioners.user_id` is a doctor member (DB default).
- Q2 default: no patient-side overlap check (a patient may hold overlapping bookings with different practitioners).
- `POST /patients` (Sprint 1 route) follows the same rule since API v2 (CTO 16:49): another tenant's `registeredBranchId` → 404, same-tenant branch without a write role → 403.
- Accepted by the CTO: `patient: null` for soft-deleted patients; Q2 / Q6 defaults.
- EF never sends DB-owned columns: appointment `status`/`cancel_reason` on insert, lifecycle timestamps, audit columns, `deleted_at`.
<!-- END API (Backend) -->
