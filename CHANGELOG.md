# Changelog

All notable changes to this project follow [Conventional Commits](https://www.conventionalcommits.org/) and [Semantic Versioning](https://semver.org/).

## [0.2.0] - Unreleased (Sprint 1: Tenant & Identity, not deployed)

### Added
- Supabase Auth in the SPA (`@supabase/supabase-js`): email/password sign-in, persisted session, protected routes, sign-out; the API client sends the current access token (never a tenant header).
- Gateway JWT validation against Supabase JWKS (ES256/RS256) with optional HS256 legacy secret; issuer/audience/lifetime checks; only `role=authenticated` user tokens accepted; fail closed when unconfigured.
- `identity.custom_access_token_hook` (tenant_id, branch_id, branch_ids, hms_roles; forged values stripped; never blocks sign-in), executable only by `supabase_auth_admin`.
- Server-side active context: `user_profiles.active_tenant_id/active_branch_id`, `identity.set_active_context`, `my_active_context`, `my_memberships`; `GET /api/v1/me` (memberships), `POST /api/v1/me/context` (validated switch) driving the tenant/branch switcher.
- Dedicated API database role `hms_api` (NOLOGIN NOINHERIT, member of authenticated/anon) + local `hms_api_login`; every API transaction runs `SET LOCAL ROLE authenticated` with `request.jwt.claims`, so RLS applies to API traffic.
- Tenant admin API + UI: branches (list/create/update/deactivate) and members (list/add with role and branch scope/role change/suspend) via `identity.add_member`.
- Patient registration form (RHF + Zod, MRN unique per tenant with 409 mapping) and patient list wired to the API.
- Tests: SQL hook/context/API-role tests (103 assertions total); integration tests on real Postgres with test-signed ES256 JWTs and a fake JWKS; RLS defense-in-depth DB tests as `hms_api_login`; full-stack Playwright with a mock GoTrue server that uses the real hook (sign-in, switching, registration, admin, cross-tenant attacks, axe).
- `scripts/clean.sh` / `npm run clean` (`--all` also removes node_modules); weekly `.github/workflows/cleanup.yml` deleting artifacts older than 7 days and caches unused for 7 days; optional `Jenkinsfile` mirror of CI with `infra/jenkins/README.md`.
- Docs: `docs/auth-flow.md`, API DB role section in the security design, Sprint 1 report.

### Changed
- CI: unit tests in the `api` job; integration + RLS tests in the `database` job (real Postgres); E2E job runs Postgres + API + mock auth; every artifact upload has `retention-days: 7` and `if-no-files-found: ignore`.
- docker-compose/db-init: API connects as `hms_api_login`; auth URL and Supabase public keys configurable.
- `user_profiles` select policy: tenant admins also see profiles of suspended members of their tenant.

### Removed
- Sprint 0 demo session and `TestAuthHandler` (replaced by real tokens in tests).

## [0.1.0] - 2026-10-06 (Sprint 0, not released or deployed)

### Added
- Monorepo layout (apps/web, backend, supabase, tests/playwright, infra, docs).
- React + Vite app shell: login placeholder with validation, tenant/branch indicator, dashboard, patient list, typed API client.
- ASP.NET Core (.NET 10) gateway with Identity/Tenant and Patients modules, a shared kernel, versioned `/api/v1` routes, OpenAPI/Swagger, Serilog JSON logging, `/health/live` and `/health/ready`, rate limiting, security headers.
- Tenant resolution from validated claims plus a server-side membership check. Client-supplied tenant headers and body fields are ignored.
- Supabase SQL migrations: `identity`, `patient`, `audit` schemas; tenants, branches, user profiles, memberships, patients, append-only audit log; RLS policies and helper functions.
- Tests: Vitest, xUnit (unit, integration, DB mapping), SQL tenant-isolation suite, Playwright + axe.
- Dockerfiles, docker-compose, Render blueprint, Vercel config, GitHub Actions CI.
