# Sprint 1 report: Tenant & Identity

_Date: 2026-10-06, around 20:40 IST. Branch `feat/sprint-1-identity`. Simulated roles: see [team-tracker.md](team-tracker.md)._

## 1. What was built

- **Supabase Auth end to end.** SPA sign-in with `@supabase/supabase-js` (email/password), persisted session, protected routes and sign-out. The API client sends the current access token and never a tenant header. Env vars `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (or `VITE_SUPABASE_ANON_KEY`) are placeholders only in `.env.example`, and no real keys are committed.
- **Gateway JWT validation.** JWKS from `<url>/auth/v1/.well-known/jwks.json` (ES256/RS256) through `ConfigurationManager`, with an optional HS256 legacy secret via `Auth:Supabase:LegacyJwtSecret`. Checks: issuer `<url>/auth/v1`, audience `authenticated`, lifetime, `role = authenticated` and a UUID `sub`. It fails closed when unconfigured, and HTTP JWKS is refused in Production.
- **Custom access token hook** `identity.custom_access_token_hook`. It adds `tenant_id`, `branch_id` (only when explicitly chosen), `branch_ids` and `hms_roles`, strips forged values and never blocks sign-in. `supabase_auth_admin` has usage and execute; everyone else is revoked.
- **Server-validated tenant/branch switching.** `GET /api/v1/me` returns all memberships. `POST /api/v1/me/context` goes through `identity.set_active_context` (a `42501`/403 for anything outside the caller's memberships). The SPA then refreshes the session and drops cached tenant data. Tokens without a tenant claim fall back to the server-side stored/default context. A present-but-invalid claim gets 403.
- **RLS for API traffic.** New role `hms_api` (NOLOGIN NOINHERIT, granted `authenticated` and `anon`) plus a login role `hms_api_login`. Every request runs in a transaction that sets `role`, `request.jwt.claims` and `request.jwt.claim.sub` with `set_config(..., true)`. A query outside a transaction is denied.
- **Tenant admin.** API (tenant_admin only) and UI for branches (list, create, rename, activate/deactivate) and members (list incl. suspended, add an existing account with role and branch scope, change role, suspend/reactivate; no self-edits).
- **Patients.** Registration form (RHF + Zod, mirrors the API/DB rules, maps a duplicate MRN to a field error via 409) and a patient list wired to the API.
- **Mock auth for E2E.** `tests/mock-auth/server.mjs` is a local GoTrue stand-in that issues ES256 tokens whose claims come from the **real** hook, executed as `supabase_auth_admin`.
- **Housekeeping.** `scripts/clean.sh` / `npm run clean` (`--all` for node_modules), CI artifact retention of 7 days, a weekly `cleanup.yml`, and an optional `Jenkinsfile` with `infra/jenkins/README.md`.
- **Docs.** [auth-flow.md](auth-flow.md), an API DB role section in [multi-tenancy-and-security.md](multi-tenancy-and-security.md), [api.md](api.md), [local-development.md](local-development.md), CHANGELOG, and a refreshed Sprint 0 report.

## 2. Test results (all run on the build box after `npm run clean`)

Environment: Debian 13, Node 24.21.0, .NET SDK 10.0.401, PostgreSQL 17.11 (local), Chromium headless shell (Playwright 1.63.0).

| Command | Result |
|---|---|
| `npm run clean` | 17 paths removed (dist, Vite cache, Playwright results, all backend bin/obj); nothing built left in the tree |
| `npm --prefix apps/web ci` / `npm ci` + `npm audit` (both) | OK, **0 vulnerabilities** |
| `npm --prefix apps/web run lint` | **0 problems** |
| `npm --prefix apps/web run test` (Vitest) | **30 passed / 0 failed** (6 files) |
| `npm --prefix apps/web run build` | OK |
| `dotnet build backend/Hms.slnx -c Release` (warnings as errors) | **0 warnings, 0 errors** |
| `dotnet test backend/Hms.slnx -c Release --filter "Category!=Database"` | **Unit 70/70 passed** (exit 0) |
| `bash supabase/scripts/run-sql-tests.sh` | **103 assertions passed, 0 failed** (7 files) |
| `dotnet test backend/Hms.slnx -c Release --filter "Category=Database"` | **Integration 46/46, Database (RLS) 16/16 passed** |
| `npm run e2e:db && CI=1 npx playwright test -c tests/playwright/playwright.config.ts` | **31 passed / 0 failed** (30 desktop + 1 mobile; JUnit: 31 tests, 0 failures) |
| Same E2E with `E2E_API_COMMAND` = self-contained gateway (the Jenkins path) | **31 passed** |
| `dotnet list backend/Hms.slnx package --vulnerable` | no vulnerable packages (7 projects) |
| `actionlint` 1.7.12 on `ci.yml` + `cleanup.yml` | OK |
| `npm-groovy-lint` 18.0.0 on `Jenkinsfile` | **0 errors**, 36 style warnings (nesting depth, line length) |

Not run: the Jenkins pipeline on a real Jenkins server; `docker compose up` (no Docker on the box); the API against tokens from the hosted Supabase project (no deployed API and no hosted `hms_api_login` yet).

## 3. Supabase project `gvgomzogbzbjhlcsimrx`

- **Migration applied:** `auth_context_and_api_role` (remote version `20261006150718` = 20:37 IST; repo file `20261007090000_auth_context_and_api_role.sql`). The SHA-256 of the stored statement matches the repo file exactly (`36f82d0a…5ee364`).
- **Verified grants:** the hook is executable only by `supabase_auth_admin` (anon/authenticated: no). `resolve_active_context` is executable by no client role. The `my_*`, `set_active_context`, `add_member` and `is_admin_of_member` functions are executable by authenticated, not anon. Every function pins `search_path=""`. `hms_api` is NOLOGIN NOINHERIT, not superuser, no BYPASSRLS, and a member of `{anon, authenticated}` with `set=t inherit=f`.
- **Advisors (after applying):**
  - Security: 1 WARN, `auth_leaked_password_protection` (an Auth setting, not schema; see §4). No schema findings.
  - Performance: 4 INFO `unused_index` (`patients_tenant_name_idx`, two `audit_log` indexes, the new `user_profiles_active_context_idx`). This is expected with no traffic. The new index backs the composite FK (removing it would raise `unindexed_foreign_keys`), so all four were kept. Nothing of ours needed fixing.
- **Live isolation check** (one transaction, `ROLLBACK` at the end, same `set_config('role'/'request.jwt.claims')` mechanism the API uses):

| # | Check | Expected | Live result |
|---|---|---|---|
| 1 | Alpha admin: patients visible, no WHERE | 4 | 4 |
| 2 | Alpha admin: Beta rows by tenant_id | 0 | 0 |
| 3 | Alpha admin: Beta patient by id | 0 | 0 |
| 4 | Alpha admin: tenants visible | Alpha only | Demo Alpha Hospital (synthetic) |
| 5 | Alpha admin: UPDATE Beta patients | 0 rows | 0 rows |
| 6 | Alpha admin: INSERT patient into Beta | 42501 | 42501 new row violates row-level security policy |
| 7 | Alpha admin: switch context to Beta | 42501 | 42501 no active membership for the requested tenant/branch |
| 8 | Alpha admin: Beta audit rows | 0 | 0 |
| 9 | Alpha admin: `my_memberships()` tenants | Alpha only | Demo Alpha Hospital (synthetic) |
| 10 | Beta doctor: patients visible | 3 | 3 |
| 11 | Beta doctor: Alpha rows | 0 | 0 |
| 12 | Outsider (no memberships): patients | 0 | 0 |
| 13 | Outsider with forged `tenant_id` + `app_metadata` claims | 0 | 0 |
| 14 | anon: patients | 42501 | 42501 permission denied for schema patient |
| 15 | authenticated calls the hook | 42501 | 42501 permission denied for function |
| 16 | `SET ROLE hms_api` (fail-closed probe) | — | inconclusive: the connector user `postgres` holds ADMIN without SET on `hms_api` (PG 16+ default), so it can't assume it. Covered locally as `hms_api_login` (DB tests). |
| 17 | Hook output (run as owner) for the consultant, with forged `tenant_id`/`hms_roles`/`branch_id` in the input | Alpha, forged values stripped | `{"role":"authenticated","hms_roles":["doctor"],"tenant_id":"1111…","branch_ids":["a111…0002"]}`. Outsider: no tenant claims. Invalid user id: claims unchanged (sign-in not blocked). |

## 4. Manual steps needed (dashboard / out-of-band)

1. **Enable the hook:** Supabase Dashboard → project `gvgomzogbzbjhlcsimrx` → **Authentication → Hooks → "Customize Access Token (JWT) Claims" → Add hook → type Postgres → schema `identity` → function `custom_access_token_hook` → Enable**. Until then tokens carry no `tenant_id`, and the API uses the stored/default context.
2. **Create the API login role** (SQL editor, with a generated password kept in Render's secret env, never in git):
   ```sql
   create role hms_api_login login noinherit password '<generated-secret>';
   grant hms_api to hms_api_login;
   ```
   The API's connection string then uses `hms_api_login` (via Supavisor, the user is `hms_api_login.gvgomzogbzbjhlcsimrx`; transaction mode on :6543 is compatible because all settings are transaction-local).
3. **Optional, Auth settings:** enable leaked-password protection (advisor WARN; may need a paid plan), and confirm email/password sign-in is enabled. The 7 synthetic users have **no passwords** on the hosted project, so set one for a demo user only if you need a manual test.
4. **Before the first `supabase db push`:** run `supabase migration repair` (remote versions are apply timestamps, not file names).

## 5. Risks

- Hook not enabled yet (manual). Switching still works through the stored context, but tokens won't carry tenant claims until it is.
- Claims in tokens can be stale for one token lifetime. Authorization never relies on them: the API and RLS re-check memberships on every request.
- `add_member` needs an existing account. Email invitations (Auth admin API, server-side) are still to come.
- Not yet verified with real hosted tokens end to end, and Docker/compose and Jenkins haven't been run.
- Audit snapshots contain PHI (S4). Free-tier limits apply (Render spin-down, Supabase pausing).

## 6. Next three tasks (Sprint 2: Patients & Appointments)

1. **Patient detail/edit and soft delete,** search by phone/DOB, duplicate-patient detection, plus audit history for tenant admins.
2. **Appointments:** an `appointment` schema (branch-scoped slots, RLS, overlap constraints), API, calendar/booking UI, and cross-tenant tests in all four layers.
3. **Transactional outbox + dispatcher skeleton** for appointment events, plus deploying the API to Render with `hms_api_login` and running a hosted-token smoke test.
