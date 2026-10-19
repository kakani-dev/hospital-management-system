# Database contracts between services

One Supabase Postgres, one migration chain (`supabase/migrations`), one outbox. Each schema has exactly
one owning service; a service touches another service's data **only** through the published `_v1`
functions below, never through its tables or views.

| Schema | Owner service | Login role (out of band) | Group role (migration) |
|---|---|---|---|
| `identity` | identity | `hms_identity_login` | `hms_svc_identity` |
| `patient` | patients | `hms_patients_login` | `hms_svc_patients` |
| `appointment` | scheduling | `hms_scheduling_login` | `hms_svc_scheduling` |
| `messaging` | shared (outbox) | – | `hms_dispatcher` (scheduling only) |

## Published functions (v1)

Every function is `SECURITY DEFINER`, `set search_path = ''` and does an **explicit tenant check**
(definer code bypasses RLS): when a signed-in user is behind the call (`auth.uid()` set) the tenant
must be one of `identity.current_tenant_ids()`, otherwise P0002 (404-not-403) or an empty result.
Callers without a user (`service_role` jobs, triggers) skip the membership check. `anon` can call none.

| Function | Owner | Used by | Added in |
|---|---|---|---|
| `identity.my_tenant_grant_v1(tenant) → jsonb` | identity | every service (tenant resolution) | 20261013090000 |
| `identity.branch_exists_v1(tenant, branch) → bool` | identity | scheduling | 20261012090000 |
| `identity.branch_tenant_id_v1(branch) → uuid` | identity | scheduling | 20261012090000 |
| `identity.branch_time_zone_v1(branch) → text` | identity | any | 20261012090100 |
| `identity.branch_local_date_v1(branch, at) → date` | identity | scheduling | 20261012090100 |
| `patient.patient_summary_v1(tenant, ids[]) → table` | patients | scheduling (embedding) | 20261013090000 |
| `patient.patient_exists_v1(tenant, patient) → bool` | patients | scheduling | 20261012090000 |
| `appointment.patient_has_open_visits_v1(tenant, patient) → bool` | scheduling | patients (soft delete) | 20261013090000 |
| `appointment.branch_has_open_activity_v1(tenant, branch) → bool` | scheduling | identity (branch soft delete) | 20261012090000 |
| `appointment.queue_has_entries_v1(tenant, branches[], days[]) → bool` | scheduling | identity (zone change lock) | 20261012090000 |
| `appointment.patient_has_active_visits_v1(tenant, patient)` | scheduling | **deprecated alias** of `patient_has_open_visits_v1` | 20261012090000 |

Details:

- `my_tenant_grant_v1` returns `{"tenant_time_zone","memberships":[{"role","branch_id"}],"branches":[{"id","timezone"}]}`
  for the caller's active, non-deleted memberships in an active, non-deleted tenant; `timezone` is the
  **effective** zone (branch override, else the tenant zone). `null` when there is no live membership.
- `patient_summary_v1` returns only `id, tenant_id, mrn, first_name, last_name, is_deleted` (no phone,
  email or DOB) for at most 500 ids (more → 22023). It **includes soft-deleted patients**
  (`is_deleted = true`) so appointment history keeps a name. Callers need one of tenant_admin, doctor,
  nurse, receptionist, billing in the tenant; otherwise the result is empty.
- Canonical names are the ones in this file (CTO decision 6). `patient_has_active_visits_v1` (the
  audit-tz name) delegates to `patient_has_open_visits_v1` and is dropped by a later contract migration.
- Grants (re-review R6): `my_tenant_grant_v1`, `patient_summary_v1` and the two zone reads are executable by
  `authenticated` (explicit tenant + role checks keyed on the session role, R4); every other `_v1` read,
  including `patient_has_open_visits_v1`, is `service_role` only and is reached through definer commands.
  A branch-scoped membership counts only while its branch is live (code review MAJ-2).

Rules: additive changes only. A breaking change ships as `_v2` next to `_v1` until no caller uses
`_v1`. Signatures are pinned by `supabase/tests/22_ms_published_contracts_test.sql`. A migration that
adds a cross-schema reference must carry the header line `-- cross-schema: approved`.

## Roles

- `hms_svc_identity`, `hms_svc_patients`, `hms_svc_scheduling` (migration 20261013090100): `NOLOGIN
  NOINHERIT`, no table privileges, members of `authenticated` and `anon`. Services keep the existing
  pattern: per transaction `SET LOCAL ROLE authenticated` + `request.jwt.claims`, so RLS applies.
- **Login roles and passwords are never in migrations.** Locally:
  `supabase/scripts/local-api-login-role.sql` (`hms_<svc>_login` / `hms_<svc>_local_only`, throwaway).
  Hosted: created out of band with a secret, then `grant hms_svc_<svc> to hms_<svc>_login`.
- `hms_dispatcher` is granted to `hms_svc_scheduling` only. The legacy `hms_api` (monolith login)
  **no longer** has it (DB review B1), so the monolith must keep `Outbox:Dispatcher:Enabled=false`.
- Pool size: about 5 connections per service (`Database:MaxPoolSize`), within the Supavisor limit.

## Outbox

- One table, `messaging.outbox`. `source_service` (`identity` | `patients` | `scheduling`) is set
  **by the database** (trigger `messaging.set_outbox_source`, from `aggregate_type`), never by the
  caller; an unknown aggregate type is rejected.
- `claim_outbox` / `complete_outbox` / `fail_outbox` only touch rows whose `source_service` belongs to
  the **calling login's** service role (derived from `session_user`, never from an argument).

## Migration chain

- File name `<14-digit version>_<snake_case>.sql`, versions unique.
- A PR's new migrations must sort after the newest migration on its base branch, and applied
  migrations are never renamed or deleted. CI enforces all three in the required database job
  (`.github/scripts/check-migration-versions.sh`).
- Expand/contract for renames: the audit columns (`created_at` → `created_on`, `updated_at` →
  `updated_on`) are kept in sync by trigger until the contract migration, so readers accept either.
