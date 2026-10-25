# Hospital Management System (HMS)

> New team? Start with [docs/HANDOVER.md](docs/HANDOVER.md).

A multi-tenant Hospital Management System: a React SPA, a YARP edge in front of six services (identity, patients, scheduling, billing, inventory, privacy), and Supabase PostgreSQL with Row Level Security. It is designed so that one platform can serve many hospitals (tenants) and their branches securely.

> **Status.** Demonstration only, **synthetic data only**, not for clinical use. The database schema lives on a Supabase project. The web app on Vercel uses the Azure Container Apps edge. The App Service `medicore-hms-api` is stopped and its project is removed from the repository. The cutover is done ([record](docs/runbooks/monolith-cutover.md)).

## Stack

| Layer | Technology |
|---|---|
| Frontend | React 19 + TypeScript, Vite, React Router, TanStack Query, Tailwind CSS v4, React Hook Form + Zod |
| Backend | ASP.NET Core (.NET 10 LTS) minimal APIs, EF Core + Npgsql, OpenAPI + Swagger UI, Serilog JSON logs, health checks |
| Database | Supabase PostgreSQL: SQL migrations, a schema per service, RLS keyed on memberships, audit log |
| Tests | Vitest (unit), xUnit (unit, API integration with signed JWTs on real Postgres, RLS defense in depth), SQL tests, full-stack Playwright + axe (mock Supabase Auth) |
| CI | GitHub Actions (`ci.yml` required gate; skips unchanged jobs, nightly full run), `cleanup.yml` weekly artifact/cache cleanup, optional Jenkins mirror |
| Hosting | Vercel (web, production on the edge), Azure Container Apps (edge + six services, 7 apps), Supabase (DB). The App Service is stopped. |

## Repository layout

```text
apps/web/                 React SPA (Supabase Auth sign-in, tenant/branch switcher, dashboard, patients, admin)
backend/
  edge/Hms.Edge           YARP edge: the single public base URL (/api/v1/*), CORS, JWT, rate limits, 503 contract
  services/*/Hms.*.Api    Microservices: identity, patients, scheduling, billing, inventory, privacy (docs/architecture/microservices.md)
  platform/Hms.Platform   Shared host plumbing: JWT auth, tenant resolution, problem mapping, Npgsql setup, health, outbox
  modules/Identity        Identity & Tenant module (/me, context switch, branches, members)
  modules/Patients        Patient module (patient registry, /api/v1/patients)
  modules/Appointments    Scheduling module (practitioners, appointments, queue)
  modules/Billing|Inventory|Privacy  OP billing + GST, stock, DPDP consent/data rights
  shared/Hms.SharedKernel Tenant context, DB session (RLS role + claims per transaction), EF interceptors
  tests/                  Hms.UnitTests, Hms.IntegrationTests (real Postgres + signed JWTs), Hms.DatabaseTests (RLS), Hms.TestHost (in-process unit host, not deployed)
supabase/
  migrations/             SQL migrations (source of truth for the schema)
  tests/                  SQL RLS / tenant-isolation tests (two synthetic tenants)
  scripts/                Local Supabase shim, local API login role, test runner
  seed.sql                SYNTHETIC demo data
tests/playwright/         Full-stack E2E + accessibility tests
tests/mock-auth/          Local GoTrue stand-in for E2E (uses the real access token hook)
scripts/clean.sh          Removes build/test artifacts (npm run clean)
Jenkinsfile               Optional Jenkins mirror of CI (infra/jenkins/README.md)
infra/aca|docker|vercel|jenkins  ACA config, Dockerfiles, Vercel config, Jenkins notes (infra/render is superseded, unused)
docs/                     Architecture, security, auth flow, ERD, API, local dev, sprint reports, team tracker
docker-compose.yml        local stack (check the file for the current service list)
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

Or run everything in containers with `docker compose up --build` (edge on :8080, web on :8081).

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
