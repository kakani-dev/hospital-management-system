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
| 0.6 | SQL migrations, RLS, helper functions, audit log, seed | Database Engineering | Done | `supabase/`, 65 SQL assertions |
| 0.7 | xUnit unit, integration and DB mapping tests | QA Automation | Done | 30 + 17 + 5 passing |
| 0.8 | Playwright E2E + axe accessibility smoke | QA Automation | Done | 14 passing |
| 0.9 | Dockerfiles, docker-compose, Render blueprint, Vercel config | DevOps | Written, **not run** (no Docker) | `infra/`, `docker-compose.yml` |
| 0.10 | GitHub Actions CI | DevOps | Written, passes actionlint, **not yet run on GitHub** | `.github/workflows/ci.yml` |
| 0.11 | Docs: architecture, security, ERD, API, local dev, report | Documentation Team | Done | `docs/` |
| 0.12 | Create GitHub repo and push | Release Management | **On hold.** The user wants a different GitHub account. | — |

## Backlog: Sprint 1 (Tenant & Identity)

| # | Task | Simulated owner |
|---|---|---|
| 1.1 | Supabase Auth in the SPA. Replace the demo session with `GET /api/v1/me`. | React Team |
| 1.2 | JWKS validation of Supabase JWTs, plus tests with signed tokens | Security Team |
| 1.3 | Custom access token hook that issues `tenant_id`/`branch_id` claims, plus a tenant/branch switch flow | Security / Database |
| 1.4 | Non-owner DB role for the API. Set `request.jwt.claims` per transaction so RLS also covers API traffic. | Database Engineering |
| 1.5 | Tenant admin UI: branches and memberships (invite, suspend) | React / .NET |
| 1.6 | Cross-tenant attack E2E tests against a running API with real tokens | QA Automation |
| 1.7 | Transactional outbox table and dispatcher skeleton | .NET Backend |
| 1.8 | Branch protection, required CI checks, PR review rules (needs the user to approve the repo setup) | Release Management |
