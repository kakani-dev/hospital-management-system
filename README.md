# Hospital Management System (HMS)

A multi-tenant Hospital Management System, built as a **modular monolith**: one ASP.NET Core API, a React SPA, and Supabase PostgreSQL with Row Level Security. It is designed so that one platform can serve many hospitals (tenants) and their branches securely.

> **Status: Sprint 0 (foundation).** Demonstration only, **synthetic data only**, not for clinical use. Nothing has been deployed.

## Stack

| Layer | Technology |
|---|---|
| Frontend | React 19 + TypeScript, Vite, React Router, TanStack Query, Tailwind CSS v4, React Hook Form + Zod |
| Backend | ASP.NET Core (.NET 10 LTS) minimal APIs, EF Core + Npgsql, OpenAPI + Swagger UI, Serilog JSON logs, health checks |
| Database | Supabase PostgreSQL: SQL migrations, a schema per service, RLS keyed on memberships, audit log |
| Tests | Vitest (unit), xUnit (unit, API integration, DB mapping), SQL tenant-isolation tests, Playwright + axe |
| CI | GitHub Actions (`.github/workflows/ci.yml`) |
| Hosting (planned, not deployed) | Vercel (web), Render Docker (API), Supabase Free (DB) |

## Repository layout

```text
apps/web/                 React SPA (app shell, login placeholder, tenant/branch indicator, dashboard, patients)
backend/
  gateway/Hms.Gateway     API host: auth, tenant resolution, rate limiting, health, OpenAPI
  modules/Identity        Identity & Tenant module (tenants, branches, memberships, /api/v1/me)
  modules/Patients        Patient module (patient registry, /api/v1/patients)
  shared/Hms.SharedKernel Tenant context, tenant-owned entity rules, EF save interceptor
  tests/                  Hms.UnitTests, Hms.IntegrationTests (WebApplicationFactory), Hms.DatabaseTests (real Postgres)
supabase/
  migrations/             SQL migrations (source of truth for the schema)
  tests/                  SQL RLS / tenant-isolation tests (two synthetic tenants)
  scripts/                Local Supabase shim + test runner
  seed.sql                SYNTHETIC demo data
tests/playwright/         E2E + accessibility smoke tests
infra/docker|render|vercel  Dockerfiles, Render blueprint, Vercel config
docs/                     Architecture, security, ERD, local dev, Sprint 0 report, team tracker
docker-compose.yml        postgres + api + web (local)
```

## Quick start

Full details are in [docs/local-development.md](docs/local-development.md).

```bash
# Database (needs PostgreSQL 15+ and psql): migrations + seed + 65 SQL assertions
npm run sql:test

# Backend
dotnet build backend/Hms.slnx
dotnet test backend/Hms.slnx --filter "Category!=Database"   # unit + API integration
dotnet test backend/tests/Hms.DatabaseTests                    # needs the DB from sql:test
ConnectionStrings__HmsDatabase="Host=localhost;Database=hms_sql_test;Username=postgres;Password=postgres" \
  dotnet run --project backend/gateway/Hms.Gateway            # http://localhost:8080/swagger

# Frontend
npm --prefix apps/web ci && npm --prefix apps/web run dev     # http://localhost:5173

# E2E
npm ci && npx playwright install chromium && npm run e2e
```

Or run everything in containers with `docker compose up --build`. (The compose stack has not been run yet, because Docker was not available in the Sprint 0 build environment.)

## Documentation

- [Architecture](docs/architecture.md)
- [Multi-tenancy & security design](docs/multi-tenancy-and-security.md)
- [ERD](docs/erd.md)
- [API](docs/api.md)
- [Local development](docs/local-development.md)
- [Sprint 0 report](docs/sprint-0-report.md)
- [Team & task tracker (simulated roles)](docs/team-tracker.md)
- [Changelog](CHANGELOG.md)

## Ground rules

- **Never trust a tenant id sent by the client.** The tenant comes from signed token claims and is checked against `identity.memberships`, both in the API and in PostgreSQL RLS.
- Only synthetic data goes into seeds, fixtures, screenshots, and demo environments.
- Any production use needs a separate legal, compliance, clinical-safety, hosting, backup, and DR review, plus explicit approval.
