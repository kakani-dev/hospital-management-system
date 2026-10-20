# ADR 0001 — Role-based access control (Level 1)

- Status: Accepted (CTO), defaults to be confirmed by Mohith — see "Decisions to confirm"
- Date: 2026-10-20
- Scope: Level 1 (tenants, branches, members, practitioners/schedules, patients, appointments, OPD queue, platform console)

## Context

Authorization was a set of role-string arrays scattered over the endpoints (`AppointmentRoles.RegWrite`,
`PatientEndpoints.WriteRoles`, `HasAnyRole(HmsRoles.TenantAdmin)`, …), with a separate copy in the web app
and in RLS. The Patients link showed for roles that then got "no access", and the defaults were broader
than the product needs (doctors and nurses could register / edit patients and book).

## Decision

1. **One permission catalog, one matrix.** `Hms.SharedKernel.Tenancy.HmsPermissions` defines the
   permissions and `ByRole` (role → permissions). Endpoints call `tenant.Can(p)`,
   `tenant.CanAtBranch(branch, p)` or `tenant.CanAtAnyBranch(p)`; no endpoint checks a role name.
2. **Server-side membership only.** Roles come from `ITenantContext`, which the tenant middleware
   resolves from the validated JWT `sub` + `identity.memberships`. Tenant, branch and role values sent by
   the client (headers, body, JWT `app_metadata`) are never trusted. Branch-scoped writes need the
   permission *at the row's branch* (unchanged rule D9).
3. **Mirrored in the database.** `identity.role_permissions` holds the same matrix and
   `identity.has_tenant_permission(tenant, permission)` is used by RLS (patients insert/update,
   appointments insert/update) and by `patient.set_patient_phones`. A unit test fails if the API, the
   migration and the web copy differ.
4. **Exposed to the UI.** `GET /api/v1/me` returns `permissions` (effective, active tenant). The web app
   hides nav links, routes, buttons and shortcuts the user lacks, and a route guard shows a friendly
   "You don't have access to this page" card with the user's role and a link back. This is UX only.
5. **Platform admin has no tenant data.** Platform operators get no tenant permissions; `/platform`
   is guarded separately by `identity.is_platform_admin()` (unchanged).

## Permission matrix

✓ = allowed, own = only for the doctor's own practitioner (see D4), — = denied (403).

| Area / action | tenant_admin | receptionist | nurse | doctor | billing | pharmacist | lab_technician | viewer | platform admin |
|---|---|---|---|---|---|---|---|---|---|
| Hospital settings — view (`settings.view`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Hospital settings — edit (`settings.manage`) | ✓ | — | — | — | — | — | — | — | — |
| Branches — view (`branches.view`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Branches — create/edit/delete (`branches.manage`) | ✓ | — | — | — | — | — | — | — | — |
| Members & invite links (`members.manage`) | ✓ | — | — | — | — | — | — | — | — |
| Practitioners & working hours — view (`practitioners.view`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Practitioners & working hours — manage (`practitioners.manage`) | ✓ | — | — | — | — | — | — | — | — |
| Patients — view (`patients.view`) | ✓ | ✓ | ✓ | ✓ | ✓ (read-only) | — | — | — | — |
| Patients — create (`patients.create`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Patients — edit (`patients.edit`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Patients — delete (`patients.delete`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Patients — restore / see deleted (`patients.restore`) | ✓ | — | — | — | — | — | — | — | — |
| Appointments — view (`appointments.view`) | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — |
| Appointments — book (`appointments.book`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Appointments — reschedule (`appointments.reschedule`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Appointments — cancel (`appointments.cancel`) | ✓ | ✓ | — | — | — | — | — | — | — |
| Appointments — check-in (`appointments.check_in`) | ✓ | ✓ | ✓ | — | — | — | — | — | — |
| Appointments — no-show (`appointments.no_show` / `_own`) | ✓ | ✓ | ✓ | own | — | — | — | — | — |
| OPD queue — view (`queue.view`) | ✓ | ✓ | ✓ | ✓ | — | — | — | — | — |
| OPD queue — walk-in, call, finish, remove (`queue.manage`) | ✓ | ✓ | ✓ | — | — | — | — | — | — |
| OPD queue — call in / finish own patients (`queue.consult_own`) | ✓ (via manage) | ✓ (via manage) | ✓ (via manage) | own | — | — | — | — | — |
| Platform console (`/platform`) | — | — | — | — | — | — | — | — | ✓ |

Free-slot lookup follows `appointments.view`. Listing branches (for forms) stays open to every member.

## Decisions (CTO defaults)

- **D1 Doctors are view-only on patients** and do not book; they see their schedule, appointments and
  queue, and can call in / finish / mark no-show for their own patients.
- **D2 Nurses** run the queue and check-in (and may mark no-show), view patients; no patient
  create/edit, no booking.
- **D3 Billing keeps read-only patients and appointments** (needed to identify patients for invoices
  later), no queue. Pharmacist and lab technician get no Level 1 patient data.
- **D4 "Own"** = the appointment's / queue entry's practitioner is linked to the caller's login
  (`appointment.practitioners.user_id`). Practitioners not linked to any login yet (all Level 1
  practitioners today) are treated as shared, so any doctor at the branch may act on them; once
  practitioners are linked to staff accounts, doctors are limited to their own.
- **D5 Viewer** = read-only on hospital settings, branches, practitioners and schedules, **no patient
  data** (patients, appointments, queue contain identifiable data).
- **D6 Members role change** already exists (PATCH `/members/{id}`, tenant_admin only). An admin cannot
  change or delete their own membership, so the acting admin always remains: the last admin cannot
  be removed. No new UI was needed.

## Consequences

- RLS migration `20261020090000_rbac_permission_matrix.sql` narrows patient and appointment writes for
  doctor/nurse. Existing data is untouched.
- Adding a role or a permission = change `HmsPermissions.ByRole`, `identity.role_permissions` (new
  migration) and `apps/web/src/lib/permissions.ts`; the matrix test keeps them equal.
