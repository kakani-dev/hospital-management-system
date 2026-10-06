# Changelog

All notable changes to this project follow [Conventional Commits](https://www.conventionalcommits.org/) and [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-06 (Sprint 0, not released or deployed)

### Added
- Monorepo layout (apps/web, backend, supabase, tests/playwright, infra, docs).
- React + Vite app shell: login placeholder with validation, tenant/branch indicator, dashboard, patient list, typed API client.
- ASP.NET Core (.NET 10) gateway with Identity/Tenant and Patients modules, a shared kernel, versioned `/api/v1` routes, OpenAPI/Swagger, Serilog JSON logging, `/health/live` and `/health/ready`, rate limiting, security headers.
- Tenant resolution from validated claims plus a server-side membership check. Client-supplied tenant headers and body fields are ignored.
- Supabase SQL migrations: `identity`, `patient`, `audit` schemas; tenants, branches, user profiles, memberships, patients, append-only audit log; RLS policies and helper functions.
- Tests: Vitest, xUnit (unit, integration, DB mapping), SQL tenant-isolation suite, Playwright + axe.
- Dockerfiles, docker-compose, Render blueprint, Vercel config, GitHub Actions CI.
