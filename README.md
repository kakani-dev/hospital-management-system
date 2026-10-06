# Hospital Management System (HMS)

A multi-tenant Hospital Management System, built as a **modular monolith**: one ASP.NET Core API, a React SPA, and Supabase PostgreSQL with Row Level Security. It is designed so that one platform can serve many hospitals (tenants) and their branches securely.

> **Status: Sprint 1 (tenant & identity).** Demonstration only, **synthetic data only**, not for clinical use. The database schema lives on a Supabase project. The API and web app are not deployed.

## Stack

| Layer | Technology |
|---|---|
| Frontend | React 19 + TypeScript, Vite, React Router, TanStack Query, Tailwind CSS v4, React Hook Form + Zod |
| Backend | ASP.NET Core (.NET 10 LTS) minimal APIs, EF Core + Npgsql, OpenAPI + Swagger UI, Serilog JSON logs, health checks |
| Database | Supabase PostgreSQL: SQL migrations, a schema per service, RLS keyed on memberships, audit log |
| Tests | Vitest (unit), xUnit (unit, API integration with signed JWTs on real Postgres, RLS defense in depth), SQL tests, full-stack Playwright + axe (mock Supabase Auth) |
| CI | GitHub Actions (`ci.yml` = required gate, `cleanup.yml` weekly artifact/cache cleanup), optional Jenkins mirror (`Jenkinsfile`) |
| Hosting (planned, not deployed) | Vercel (web), Render Docker (API), Supabase Free (DB) |

## Repository layout

```text
apps/web/                 React SPA (Supabase Auth sign-in, tenant/branch switcher, dashboard, patients, admin)
backend/
  gateway/Hms.Gateway     API host: auth, tenant resolution, rate limiting, health, OpenAPI
  modules/Identity        Identity & Tenant module (/me, context switch, branches, members)
  modules/Patients        Patient module (patient registry, /api/v1/patients)
  shared/Hms.SharedKernel Tenant context, DB session (RLS role + claims per transaction), EF interceptors
  tests/                  Hms.UnitTests, Hms.IntegrationTests (real Postgres + signed JWTs), Hms.DatabaseTests (RLS)
supabase/
  migrations/             SQL migrations (source of truth for the schema)
  tests/                  SQL RLS / tenant-isolation tests (two synthetic tenants)
  scripts/                Local Supabase shim, local API login role, test runner
  seed.sql                SYNTHETIC demo data
tests/playwright/         Full-stack E2E + accessibility tests
tests/mock-auth/          Local GoTrue stand-in for E2E (uses the real access token hook)
scripts/clean.sh          Removes build/test artifacts (npm run clean)
Jenkinsfile               Optional Jenkins mirror of CI (infra/jenkins/README.md)
infra/docker|render|vercel|jenkins  Dockerfiles, Render blueprint, Vercel config, Jenkins notes
docs/                     Architecture, security, auth flow, ERD, API, local dev, sprint reports, team tracker
docker-compose.yml        postgres + api + web (local)
```

## Quick start

Full details are in [docs/local-development.md](docs/local-development.md).

```bash
# Database (needs PostgreSQL 15+ and psql): migrations + seed + 103 SQL assertions
npm run sql:test

# Backend
dotnet build backend/Hms.slnx
dotnet test backend/Hms.slnx --filter "Category!=Database"   # unit tests
dotnet test backend/Hms.slnx --filter "Category=Database"    # integration + RLS tests (needs the DB from sql:test)

# Frontend
npm --prefix apps/web ci && npm --prefix apps/web run dev     # http://localhost:5173

# Full-stack E2E (mock Supabase Auth + API + web + Postgres)
npm ci && npx playwright install chromium && npm run e2e:db && npm run e2e

# Remove build/test artifacts
npm run clean
```

Or run everything in containers with `docker compose up --build`. (The compose stack has not been run yet, because Docker was not available in the build environment.)

## Documentation

- [Architecture](docs/architecture.md)
- [Multi-tenancy & security design](docs/multi-tenancy-and-security.md)
- [Authentication & tenant context flow](docs/auth-flow.md)
- [ERD](docs/erd.md)
- [API](docs/api.md)
- [Local development](docs/local-development.md)
- [Sprint 1 report](docs/sprint-1-report.md) · [Sprint 0 report](docs/sprint-0-report.md)
- [Jenkins (optional mirror)](infra/jenkins/README.md)
- [Team & task tracker (simulated roles)](docs/team-tracker.md)
- [Changelog](CHANGELOG.md)

## Ground rules

- **Never trust a tenant id sent by the client.** The tenant comes from signed token claims and is checked against `identity.memberships`, both in the API and in PostgreSQL RLS.
- Only synthetic data goes into seeds, fixtures, screenshots, and demo environments.
- Any production use needs a separate legal, compliance, clinical-safety, hosting, backup, and DR review, plus explicit approval.
