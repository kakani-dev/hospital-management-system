# Team & task tracker

> **Simulated roles.** No real multi-agent team was used. One AI agent did all the work in sequence, acting in each role below. Role names show who would own each area in a real team.

## Sprint 0: Foundation (2026-10-06)

| # | Task | Simulated owner | Status | Evidence |
|---|---|---|---|---|
| 0.1 | Monorepo layout, `.editorconfig`, `.gitignore`, conventional commits | Release Management | Done | repo root |
| 0.2 | Architecture: modular monolith, schema per service | CTO / Solution Architect | Done | `docs/architecture.md` |
| 0.3 | React + Vite app shell, typed API client, accessible components | React Team, UI/UX | Done | `apps/web`, 6 Vitest tests |
| 0.4 | ASP.NET Core gateway, Identity and Patients modules, shared kernel | .NET Backend Team | Done | `backend/`, 0 build warnings |
| 0.5 | Tenant resolution from claims plus a membership check | Security Team | Done (JWKS validation is a Sprint 1 TODO) | `ClaimsTenantResolver`, integration tests |
| 0.6 | SQL migrations, RLS, helper functions, audit log, seed | Database Engineering | Done | `supabase/`, 67 SQL assertions |
| 0.7 | xUnit unit, integration and DB mapping tests | QA Automation | Done | 30 + 17 + 5 passing |
| 0.8 | Playwright E2E + axe accessibility smoke | QA Automation | Done | 14 passing |
| 0.9 | Dockerfiles, docker-compose, Render blueprint, Vercel config | DevOps | Written, **not run** (no Docker) | `infra/`, `docker-compose.yml` |
| 0.10 | GitHub Actions CI | DevOps | Written, passes actionlint, **not yet run on GitHub** | `.github/workflows/ci.yml` |
| 0.11 | Docs: architecture, security, ERD, API, local dev, report | Documentation Team | Done | `docs/` |
| 0.12 | Create GitHub repo and push | Release Management | **On hold.** The user wants a different GitHub account. | — |

## Sprint 1 (Tenant & Identity)

| # | Task | Simulated owner | Status |
|---|---|---|---|
| 1.1 | Supabase Auth in the SPA. Replace the demo session with `GET /api/v1/me`. | React Team | Done |
| 1.2 | JWKS validation of Supabase JWTs, plus tests with signed tokens | Security Team | Done (test-signed tokens + fake JWKS; mock GoTrue in E2E) |
| 1.3 | Custom access token hook issuing `tenant_id`/`branch_id`, plus a tenant/branch switch flow | Security / Database | Done. The function is applied; **enabling it in the Auth dashboard is a manual step**. |
| 1.4 | Non-owner DB role for the API, with `request.jwt.claims` set per transaction | Database Engineering | Done locally. The hosted `hms_api_login` must be created out-of-band. |
| 1.5 | Tenant admin UI: branches and memberships (add, role change, suspend) | React / .NET | Done (adds existing accounts; email invitations deferred) |
| 1.6 | Cross-tenant attack E2E tests against a running API with real tokens | QA Automation | Done |
| 1.7 | Clean script, CI artifact retention, cleanup workflow, Jenkins mirror | DevOps | Done (Jenkinsfile linted, **not run on a Jenkins server**) |
| 1.8 | Branch protection, required CI checks, PR review rules | Release Management | Waiting on user approval |

## Backlog: Sprint 2 (Patients & Appointments)

| # | Task | Simulated owner |
|---|---|---|
| 2.1 | Patient detail/edit + soft delete, search by phone/DOB, duplicate detection | React / .NET |
| 2.2 | Appointment schema (`appointment` schema, RLS, branch-scoped slots), API and calendar UI | Database / .NET / React |
| 2.3 | Transactional outbox + dispatcher skeleton (appointment events) | .NET Backend |
| 2.4 | Member invitations via Supabase Auth admin API (server-side), deploy API to Render with `hms_api_login` | Security / DevOps |
