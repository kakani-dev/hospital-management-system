# API (v1)

The live contract is the OpenAPI document at `/openapi/v1.json`, with Swagger UI at `/swagger` (Development). Auth flow details: [auth-flow.md](auth-flow.md).

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/health/live` | anonymous | Liveness (process only) |
| GET | `/health/ready` | anonymous | Readiness (includes the database, as the API role) |
| GET | `/api/v1/me` | JWT | Current user, server-resolved active tenant/branch, roles, accessible branches `[{id, name, timeZone}]` (effective IANA zone), **all** memberships (drives the switcher), and `timeZone` (tenant zone). A branch-scoped membership only counts while its branch is not deleted. |
| POST | `/api/v1/me/context` | JWT | `{tenantId, branchId?}`: validated against memberships in the DB (403 otherwise) and stored. Refresh the session afterwards to get a token for the new tenant. 204 on success. |
| GET | `/api/v1/tenants/current` | JWT + tenant | `{id, code, name, activeBranchId, roles, timeZone}` |
| PATCH | `/api/v1/tenants/current` | tenant_admin | `{name?, timeZone?, confirmFutureBookings?}`. `timeZone` must be a canonical IANA id (`Asia/Calcutta` is stored as `Asia/Kolkata`; `Etc/GMT±N`, POSIX offsets like `Asia/Kolkata+5` and abbreviations are 400, with a "Did you mean" hint). 409 `time_zone_locked` while today's queue has entries at an affected branch. 409 `time_zone_has_future_bookings` with `futureBookings: N` when booked appointments would move on the wall clock: nothing is saved (name included); resend with `confirmFutureBookings: true`. Branches without an override follow the new zone. |
| GET | `/api/v1/branches` | JWT + tenant | `BranchDto[]` `{id, code, name, timezone, isActive, timezoneOverride, isDeleted}` of the current tenant: `timezone` is the effective zone, `timezoneOverride` is null when the branch inherits the tenant zone. Admins also see inactive ones, and deleted ones with `?includeDeleted=true` (to restore them). |
| POST | `/api/v1/branches` | tenant_admin | `{code, name, timezone?}`: code `^[a-z0-9][a-z0-9-]{1,39}$`; `timezone` is an optional override (same rules as the tenant zone), omitted = inherit. 409 on duplicate code. |
| PATCH | `/api/v1/branches/{id}` | tenant_admin | `{name?, timezone?, inheritTimezone?, isActive?, confirmFutureBookings?}`. `timezone` sets the override, `inheritTimezone: true` clears it. Zone changes have the same 409 `time_zone_locked` / `time_zone_has_future_bookings` rules as the tenant. Another tenant's id gives 404. |
| DELETE | `/api/v1/branches/{id}` | tenant_admin | 204 soft delete (`identity.soft_delete_branch`). Staff memberships scoped to the branch stop granting anything until it is restored. 404 foreign/unknown/already deleted. |
| POST | `/api/v1/branches/{id}/restore` | tenant_admin | 204. 404 if foreign, unknown or not deleted; 409 if a live branch now uses the code. |
| GET | `/api/v1/members` | tenant_admin | Memberships of the current tenant (including suspended; not pending invites), with email and branch |
| POST | `/api/v1/members` | tenant_admin | `{email, role, branchId?}`: invites an account. Always the same **202** `{message}` whether or not the account exists or is already a member (no enumeration). A second branch creates a separate pending invite; the same branch is a no-op. 400 for a tenant_admin with a branch or another tenant's branch. |
| PATCH | `/api/v1/members/{id}` | tenant_admin | `{role?, status? (active/suspended)}`. You can't change your own membership (409). Pending invites are not visible to admins (404). |
| DELETE | `/api/v1/members/{id}` | tenant_admin | 204 soft delete (`identity.soft_delete_membership`). 404 foreign/unknown/already deleted. |
| POST | `/api/v1/members/{id}/restore` | tenant_admin | 204. 404 if foreign, unknown or not deleted; 409 if a live duplicate exists. |

Creating a tenant is **not** a monolith endpoint: it lives in the identity service (code review MIN-5) on top of the DB function `identity.create_tenant(code, name, time_zone, admin_email)`.

### Audit fields, soft delete and time zones (PR #4)

- Every identity/patient/appointment row carries `createdOn`/`updatedOn` (instants) in DTOs that expose audit times (`PatientDetailDto`, `AppointmentDto`); the former `createdAt`/`updatedAt` names are gone from the API. `createdBy`/`updatedBy` are stamped by the database and not exposed.
- Deletes are soft (`is_deleted`), via `DELETE` + `POST …/restore` on patients, branches, members, practitioners and schedules. Deleted rows read as 404.
- Branch-local dates and slot times use the branch's effective zone (`timezoneOverride` ?? tenant `timeZone`). Slots are DST-safe: on a fall-back night each wall-clock slot is offered once; on a spring-forward night the missing local times are not offered.
| GET | `/api/v1/me/invitations` | JWT | The caller's pending invitations `[{membershipId, tenantId, tenantName, branchId, role, invitedAt}]` |
| POST | `/api/v1/me/invitations/{membershipId}/accept` | JWT (the invitee) | 204; 404 if it isn't the caller's pending invitation |

## Sprint 2: patients, scheduling, appointments, OPD queue

Contract: `SPRINT2-CONTRACT.md` (DB v4 + API v2, 16:50 IST). JSON is camelCase; `date` = `YYYY-MM-DD`, `time` = `HH:mm` (branch-local wall clock), instants are ISO-8601 (responses in UTC). `Paged<T>` = `{items, page, pageSize, totalCount}` (`pageSize` 1..100, default 25).

Role shorthand: **REG_READ** = tenant_admin, doctor, nurse, receptionist, billing · **REG_WRITE** = tenant_admin, doctor, nurse, receptionist · **FRONT_DESK** = tenant_admin, receptionist, nurse · **ADMIN** = tenant_admin. **@branch** means the role must be held *at* the row's branch (tenant_admin is tenant-wide). Reads are tenant-wide, except the queue board and slots, which also need access to the branch.

### Patients (2.1)

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/v1/patients?page=&pageSize=` | REG_READ | `Paged<PatientSummaryDto>`, soft-deleted rows excluded. `?search=` is a 400 (no PHI in URLs). |
| POST | `/api/v1/patients/search` | REG_READ | `{search?, phone?, dateOfBirth?, includeDeleted?, page?, pageSize?}`, filters AND-ed. `search`: MRN/first/last contains (≤ 100). `phone`: exact match on the normalized last 10 digits of any live number in `patient_phones` (phone or WhatsApp; fewer than 7 digits is a 400). `includeDeleted`: tenant_admin only (403 otherwise). |
| POST | `/api/v1/patients/duplicates` | REG_WRITE (any branch) | `{firstName?, lastName?, dateOfBirth?, phone?, excludePatientId?}` → `{candidates: DuplicateCandidateDto[]}`: same-tenant, non-deleted matches on name+DOB (trimmed, case-insensitive) or normalized phone, `matchReasons` ⊆ `name_dob`, `phone`; both-reasons first, then name; at most 20. Advisory only. 403 without registry access. |
| GET | `/api/v1/patients/{id}` | REG_READ | `PatientDetailDto` (adds `email`, `createdOn`, `updatedOn`). 404 for other tenants and for deleted patients (admins too). |
| POST | `/api/v1/patients` | REG_WRITE @registeredBranchId | 201 `PatientCreatedDto` = detail + `duplicateWarnings` (advisory; creation is never blocked). The MRN is generated server-side (`<TENANT CODE>-<6 digits>`, per-tenant counter); a client `mrn` is ignored. `phone` and `whatsapp: {sameAsPhone, number?}` are normalised to E.164 with the hospital's default country code; the response has `phones[]` and `whatsappSameAsPhone`. 403 for a same-tenant branch without a write role, 404 for another tenant's or an unknown branch, 400 `errors.phone` / `errors.whatsapp`. |
| PATCH | `/api/v1/patients/{id}` | REG_WRITE @current branch, and @new branch when `registeredBranchId` changes | Merge-patch: absent = unchanged, explicit `null` clears `dateOfBirth`/`phone`/`email`/`whatsapp`. `mrn` is immutable (a different value is 400); unknown properties are 400 (a `tenantId` is ignored). 404 for deleted or foreign patients, or a move to another tenant's branch. |
| DELETE | `/api/v1/patients/{id}` | tenant_admin, or receptionist @patient's branch | Optional body `{reason?}` (≤ 500, audited). 204 soft delete through `patient.soft_delete_patient`. 409 `invalid_state` while the patient has open appointments or queue entries. The MRN stays reserved. |
| POST | `/api/v1/patients/{id}/restore` | ADMIN | 204. 403 for other roles, 404 if foreign, unknown or not deleted. |

### Practitioners, schedules and slots (2.2)

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/v1/practitioners?activeOnly=&branchId=` | any member | `PractitionerDto[]` `{id, userId, displayName, specialty, isActive}`, by name. With `branchId`: only practitioners with an active schedule at that branch (404 for another tenant's branch). `activeOnly` defaults to true. |
| POST | `/api/v1/practitioners` | ADMIN | `{displayName (1..120), specialty?, userId?}` → 201. 409 if the user is already linked. |
| PATCH | `/api/v1/practitioners/{id}` | ADMIN | `{displayName?, specialty? ("" clears), userId?, unlinkUser?, isActive?}`. Inactive practitioners can't be booked. |
| GET | `/api/v1/schedules?branchId=&practitionerId=` | any member | `ScheduleDto[]` `{id, practitionerId, branchId, weekday (ISO 1=Mon), startTime, endTime, slotMinutes, validFrom, validTo, isActive}` |
| POST | `/api/v1/schedules` | ADMIN @branch | `{practitionerId, branchId, weekday, startTime, endTime, slotMinutes? (5..240, default 15), validFrom? (default branch today), validTo?}`. Branch-local times, no overnight shifts (400). 409 `schedule_overlap` for the same practitioner. |
| PATCH | `/api/v1/schedules/{id}` | ADMIN | `{weekday?, startTime?, endTime?, slotMinutes?, validFrom?, validTo?, clearValidTo?, isActive?}`; practitioner and branch are immutable. 409 `schedule_overlap`. |
| DELETE | `/api/v1/schedules/{id}` | ADMIN | 204 |
| GET | `/api/v1/slots?branchId=&from=&to=&practitionerId=` | REG_READ + branch access | Free future slots `SlotDto[]` `{practitionerId, branchId, startsAt, endsAt}` computed from schedules minus blocking bookings. `from`/`to` are branch-local dates, inclusive, at most 31 days apart (400). 403 for a same-tenant branch outside your scope. |

### Appointments (2.2)

Statuses: `booked` → `checked_in` (only via check-in) → `in_consultation` → `completed`; `booked` → `cancelled` / `no_show` (no-show only once the start has passed); `checked_in` → `cancelled`. Anything else is 409 `invalid_transition`. Time, practitioner, patient and branch can only change while `booked`.

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/v1/appointments?branchId=&practitionerId=&patientId=&date=&from=&to=&status=&page=&pageSize=` | REG_READ (tenant-wide) | `Paged<AppointmentDto>` by `startsAt`. `date` is branch-local and needs `branchId`; otherwise use the `from`/`to` instants. |
| GET | `/api/v1/appointments/{id}` | REG_READ | `AppointmentDto` `{id, branchId, practitionerId, patientId, patient, startsAt, endsAt, status, reason, cancelReason, checkedInAt, startedAt, completedAt, cancelledAt, createdOn, updatedOn}`. `patient` = `{id, mrn, firstName, lastName}`, or `null` when the patient is soft-deleted or not readable. |
| POST | `/api/v1/appointments` | REG_WRITE @branchId | `{branchId, practitionerId, patientId, startsAt, endsAt (> startsAt, ≤ 8 h), reason? (≤ 500)}` → 201 `booked`. **409 `appointment_overlap`** when the practitioner already has a booked/checked-in/in-consultation/completed appointment overlapping `[startsAt, endsAt)` (back-to-back is fine; cancelled and no-show free the time; patient-side overlap is allowed). 400 for an inactive practitioner. |
| POST | `/api/v1/appointments/{id}/reschedule` | REG_WRITE @its branch | `{startsAt, endsAt, practitionerId?}`, only while booked. 409 `appointment_overlap` / `invalid_transition`. |
| POST | `/api/v1/appointments/{id}/cancel` | REG_WRITE @its branch | `{reason?}` → 200 `cancelled`. Cancelling a `checked_in` appointment also cancels its OPD queue entry (DB trigger, migration `20261010090400`), so it leaves the active board and no longer blocks patient delete. |
| POST | `/api/v1/appointments/{id}/no-show` | REG_WRITE @its branch | 200 `no_show`; 409 `invalid_transition` before the start or when not booked |

### Check-in and OPD queue (2.3)

Tokens are numbered from 1 per branch per **branch-local** day, shared by appointment check-ins and walk-ins, and allocated atomically (a rolled-back request may leave a gap). A patient has at most one active (waiting or in-consultation) entry per branch per day.

| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/api/v1/appointments/{id}/check-in` | FRONT_DESK @appointment's branch | 201 `CheckInResultDto` `{queueEntryId, tokenNo, queueDate, entry}`; the appointment becomes `checked_in`. Only on the appointment's branch-local day (409 `invalid_state`). 409 `already_checked_in` / `invalid_transition`. |
| POST | `/api/v1/queue/walk-in` | FRONT_DESK @branchId | `{branchId, patientId, practitionerId?}` → 201 `CheckInResultDto` (no appointment; no practitioner = any doctor). 409 `already_checked_in`. |
| GET | `/api/v1/queue?branchId=&date=&status=` | REG_READ + branch access | `QueueEntryDto[]` `{id, branchId, queueDate, tokenNo, patientId, patient, appointmentId, practitionerId, status, checkedInAt, calledAt, completedAt, cancelledAt}` (`patient` as on appointments) ordered by `tokenNo`; `date` defaults to the branch-local today. |
| PATCH | `/api/v1/queue/{id}` | FRONT_DESK @branch; doctor @branch for `in_consultation`/`done` | `{status}` = `in_consultation`, `done` or `cancelled`: waiting → in_consultation/cancelled, in_consultation → done/cancelled. The linked appointment follows (in_consultation, completed, cancelled). 409 `invalid_transition`. |

### Outbox (2.4, no HTTP routes)

Appointment and queue changes write events (`appointment.*`, `queue.token_issued`, `queue.status_changed`) to `messaging.outbox` from DB triggers in the same transaction; the payload carries ids, status and times only (no PHI). The gateway's `OutboxDispatcher` (off by default: `Outbox:Dispatcher:Enabled`) claims batches as `hms_dispatcher` with SKIP LOCKED leases and publishes at least once; consumers dedupe on `eventId`.

## Errors

Errors use RFC 7807 problem details with an optional machine-readable `code`:

| Status | When | `code` |
|---|---|---|
| 400 | Validation (`errors` per field), invalid parameter, check violation | `invalid_parameter`, `check_violation`, `invalid_reference` |
| 401 | Missing, invalid or expired token (empty body) | |
| 403 | No membership, role not allowed, or a **same-tenant** branch outside your scope (or rejected by RLS) | `forbidden` |
| 404 | Unknown id, **another tenant's** id (patient, practitioner, appointment, queue entry, schedule or branch, in the path or body), or a soft-deleted patient. These are indistinguishable. | `not_found` |
| 409 | Duplicate, overlap, wrong state or invalid transition | `duplicate_mrn`, `already_checked_in`, `schedule_overlap`, `appointment_overlap`, `invalid_transition`, `invalid_state` |
| 429 | Rate limited (`Retry-After`) | `rate_limited` |
| 503 | A service is cold/unreachable, or the signing keys (JWKS) cannot be fetched. Retry after `Retry-After` (5 s). | `service_unavailable` |
| 504 | A service took longer than 30 s | `upstream_timeout` |

All of these come through the single edge (`docs/architecture/microservices.md`). `GET /api/v1/warmup` (anonymous, 10/min per IP) wakes every service and returns 200, or 503 while one is still starting.

**Tenant selection.** There is no tenant header. The tenant comes from the validated token's `tenant_id` claim (set by the access token hook), or from the server-side stored context when the token has none. Either way it must match an active membership, and PostgreSQL RLS enforces the same rule again for every query.
