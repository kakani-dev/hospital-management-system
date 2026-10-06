# Sprint 0 report: Foundation

_Date: 2026-10-06 (IST). Prepared by the simulated CTO / orchestrator role. See [team-tracker.md](team-tracker.md)._

## 1. Work completed

- **Monorepo** following brief §9: `apps/web`, `backend/{gateway,modules,shared,tests}`, `supabase/{migrations,tests,seed.sql}`, `tests/playwright`, `infra/{docker,render,vercel}`, `docs`, `.github/workflows`, `docker-compose.yml`.
- **Frontend** (`apps/web`): React 19, Vite 8, React Router, TanStack Query, Tailwind v4, React Hook Form + Zod. It includes a login placeholder with validation, a protected app shell with skip link, primary nav, tenant/branch indicator and switcher, dashboard (API health), patient list (search, empty and error states), 404, and a typed API client that never sends a tenant header.
- **Backend** (`backend`): .NET 10 solution with `Hms.Gateway`, `Hms.Modules.Identity`, `Hms.Modules.Patients` and `Hms.SharedKernel`. It provides EF Core + Npgsql (snake_case), OpenAPI + Swagger UI, Serilog JSON logs, `/health/live` and `/health/ready`, `/api/v1` routes, rate limiting, CORS, security headers, tenant resolution middleware, and RFC 7807 errors.
- **Database** (`supabase`): 6 migrations creating the `identity`, `patient` and `audit` schemas. Tables: tenants, branches, user_profiles, memberships, patients, audit_log. Also included: tenant-scoped unique constraints and composite FKs, indexes, audit-column and tenant-immutability triggers, an append-only audit log, RLS on every table, membership-based helper functions, and column-level grants. The seed contains synthetic data only (2 tenants, 3 branches, 7 users, 7 patients).
- **Infra**: API and web Dockerfiles, nginx config, docker-compose (postgres + api + web), Render blueprint, Vercel config + README, CI workflow (4 jobs).

## 2. Test commands and verified results

These were run on the build box (Debian 13, Node 24.21.0, .NET SDK 10.0.401, PostgreSQL 17.11), after a clean reinstall and rebuild:

| Command | Result |
|---|---|
| `npm --prefix apps/web ci` | OK |
| `npm --prefix apps/web run lint` (ESLint + jsx-a11y) | **0 problems** |
| `npm --prefix apps/web run test` (Vitest) | **6 passed / 0 failed** (3 files) |
| `npm --prefix apps/web run build` (tsc + vite) | OK |
| `dotnet build backend/Hms.slnx -c Release` (warnings as errors) | **0 warnings, 0 errors** |
| `dotnet test backend/Hms.slnx -c Release --filter "Category!=Database"` | **Unit 30/30, Integration 17/17 passed** |
| `bash supabase/scripts/run-sql-tests.sh` | **65 assertions passed, 0 failed** (5 test files) |
| `dotnet test backend/tests/Hms.DatabaseTests --filter Category=Database` | **5/5 passed** (EF against real migrated Postgres) |
| `npx playwright test -c tests/playwright/playwright.config.ts` | **14 passed / 0 failed** (13 desktop + 1 mobile, Chromium headless shell) |
| `actionlint .github/workflows/ci.yml` | OK |
| `npm audit` (web + root) / `dotnet list package --vulnerable` | 0 known vulnerabilities |
| Manual gateway smoke against Postgres | `/health/live` 200, `/health/ready` 200 (DB check), `/api/v1/patients` without a token → 401, with a forged token + `X-Tenant-Id` → 401, `/openapi/v1.json` 200 (4 paths), `/swagger` 200 |

**Harness sanity check:** with RLS disabled on `patient.patients`, the SQL suite **failed** as expected ("not ok - alpha admin sees exactly the 4 Alpha patients"). The DB was then recreated.

## 3. Not run / not verified

| Item | Why |
|---|---|
| `docker build` / `docker compose up` | Docker is not installed on the build box (and was deliberately not installed). The DB init script logic was run against local Postgres instead. |
| GitHub Actions run | No repo yet. Repo creation and push are **on hold** because the user wants a different GitHub account. |
| Render / Vercel / Supabase deploys | Out of scope for Sprint 0. Not authorised. |
| Supabase JWT validation with real tokens | No Supabase project. Code path is TODO(Sprint 1). |
| `supabase` CLI (`supabase db push/test`) | Not installed. Migrations were applied with psql plus the local shim on vanilla PostgreSQL 17. |
| Playwright `--with-deps` | `apt-get update` failed inside the Playwright installer (Debian repo signature error), so Chromium was installed without system deps. The existing system libs were enough. |

## 4. Tenant isolation and security checks performed

- **SQL (65 assertions):** these cover cross-tenant SELECT by tenant_id, primary key and name search; UPDATE and DELETE affecting 0 rows; INSERT with a foreign tenant_id rejected (42501); self-granting a membership in another tenant rejected; moving a patient between tenants rejected; no hard delete; anon denied; an outsider sees nothing; a suspended tenant loses access; a forged `app_metadata.tenant_id` without a membership grants nothing; branch scope on insert and update; receptionist cannot escalate; lab tech has no registry access; tenant-scoped MRN and branch-code uniqueness; cross-tenant composite FKs rejected; tenant_id immutable via trigger; audit rows tenant- and actor-stamped, visible only to that tenant's admin, append-only, not truncatable; every tenant-owned table has NOT NULL tenant_id; RLS enabled everywhere; anon has no grants; SECURITY DEFINER functions pin search_path.
- **API (integration):** a spoofed `X-Tenant-Id` is ignored; `tenantId` in a POST body is ignored and the resolved tenant is used; a token tenant without a membership gets 403; no tenant claim gets 403; another tenant's patient id gets 404; a cross-tenant branch on create gets 403; receptionist branch scope enforced; lab tech gets 403; validation gives 400; duplicate MRN gives 409; `/me` returns only server-side memberships; branch claim validated.
- **EF:** the query filter isolates tenants (InMemory and real Postgres); the interceptor overwrites a client tenant id, blocks tenant changes, and throws without a tenant; soft-deleted rows are hidden.

## 5. Deployment status

Nothing has been deployed. There are no URLs.

## 6. Risks and blockers

1. **Blocker:** the GitHub repo has not been created. The user is choosing which GitHub account to use. Local commits exist under the author identity `Mohith Kakani <84347625+kakani17481a0566@users.noreply.github.com>`, which may need to be rewritten for the new account before the first push.
2. API → Postgres currently uses an owner/superuser connection, so RLS does not apply to API traffic. Isolation there depends on the EF filters and checks (tested). Fix in Sprint 1 (security gap S2).
3. Supabase JWT validation is unverified (S1), and there is no custom access token hook yet (S3). Until then, protected endpoints are reachable only in tests.
4. The Docker images and compose stack have not been built.
5. Audit snapshots contain PHI (S4). Free tiers (Render spin-down, Supabase limits, Vercel Hobby terms) must be re-checked before any deploy.

## 7. Next three development tasks

1. **Supabase Auth end to end:** SPA sign-in, JWKS validation in the gateway, a custom access token hook issuing `tenant_id`/`branch_id`, and `/api/v1/me` driving the tenant/branch switcher.
2. **RLS for API traffic:** a dedicated least-privilege DB role for the API, with per-transaction `set_config('request.jwt.claims', …)` so the PostgreSQL policies also protect API queries. Add tests that prove it.
3. **Tenant admin and patient registration slice:** branch and membership management plus a patient registration form (RHF + Zod → `POST /api/v1/patients`), with Playwright cross-tenant attack tests against a running API.
