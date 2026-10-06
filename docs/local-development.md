# Local development guide

## Prerequisites

| Tool | Version used in Sprint 0 | Notes |
|---|---|---|
| Node.js | 24 LTS (24.21.0) | Vite 8, jsdom and friends need Node ≥ 22.12. Node 20 is too old. |
| .NET SDK | 10.0.401 (.NET 10 LTS) | `backend/global.json` pins 10.0.100 with `rollForward: latestFeature` |
| PostgreSQL + psql | 17.11 | Any PostgreSQL 15+ works (`UNIQUE NULLS NOT DISTINCT`) |
| Docker (optional) | — | For `docker compose up` |
| Supabase CLI (optional) | — | For a full local Supabase stack. Not needed for the tests. |

## 1. Database

```bash
# Creates a THROWAWAY database (default hms_sql_test, dropped and recreated each run),
# installs the local Supabase shim, applies migrations + synthetic seed, runs the SQL tests.
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres npm run sql:test
```

- `supabase/scripts/local-supabase-shim.sql` creates the `anon`, `authenticated` and `service_role` roles, plus `auth.users`, `auth.uid()` and `auth.jwt()`, **only when they don't already exist**. Never run it against a hosted Supabase project.
- On a real Supabase project, apply `supabase/migrations` with `supabase db push`, or let the Supabase GitHub integration do it. Expose the `identity` and `patient` schemas in API settings only if PostgREST access is wanted. The migrations themselves contain no `auth` stand-ins; Supabase already provides `auth.users`, `auth.uid()`, `auth.jwt()` and the roles.
- Seeding a hosted project (synthetic data only): run `supabase/scripts/hosted-auth-users.sql` first (it creates the 7 demo users with the extra columns GoTrue needs, **without passwords**, so nobody can sign in as them), then `supabase/seed.sql`.
- If migrations were applied through the Supabase dashboard/MCP instead of the CLI, the remote migration history uses the apply time as version, not the file timestamp. Run `supabase migration repair` before the first `supabase db push` so the CLI does not try to re-apply them.
- SQL tests impersonate users the way PostgREST does: `set local role authenticated` plus `request.jwt.claims` (see `supabase/tests/00_test_helpers.sql`).

## 2. Backend

```bash
dotnet build backend/Hms.slnx
dotnet test backend/Hms.slnx --filter "Category!=Database"     # no DB needed (EF InMemory)
dotnet test backend/tests/Hms.DatabaseTests                      # needs the hms_sql_test DB from step 1

export ConnectionStrings__HmsDatabase="Host=localhost;Database=hms_sql_test;Username=postgres;Password=postgres"
dotnet run --project backend/gateway/Hms.Gateway                 # http://localhost:8080
curl localhost:8080/health/ready
open http://localhost:8080/swagger
```

Configuration (environment variables use `__` for nesting):

| Key | Purpose |
|---|---|
| `ConnectionStrings__HmsDatabase` | Npgsql connection string |
| `Auth__Supabase__ProjectUrl` | `https://<ref>.supabase.co`. If empty, every bearer token is rejected. |
| `Cors__AllowedOrigins__0..n` | Allowed SPA origins |
| `RateLimiting__PermitPerMinute` | Per user/IP fixed window (default 120) |
| `OpenApi__Enabled` | Swagger/OpenAPI outside Development |

`/api/v1/patients` needs a valid Supabase JWT carrying a tenant claim. Until Sprint 1 wires up Supabase Auth, protected endpoints return 401 locally. Use the integration tests (`TestAuthHandler`) to exercise them.

## 3. Frontend

```bash
cp apps/web/.env.example apps/web/.env   # optional
npm --prefix apps/web ci
npm --prefix apps/web run dev            # http://localhost:5173 (proxies /api and /health to :8080)
npm --prefix apps/web run lint
npm --prefix apps/web run test
npm --prefix apps/web run build
```

The login screen is a placeholder. Any well-formed email plus an 8+ character password creates a synthetic demo session for "Demo Alpha Hospital".

## 4. End-to-end tests

```bash
npm ci
npx playwright install --with-deps chromium   # or without --with-deps if system libs exist
npm run e2e                                   # builds apps/web and serves it with vite preview on :4173
```

The suite passes whether or not the API is running. It asserts graceful degradation either way.

## 5. Docker Compose

```bash
docker compose up --build
# web http://localhost:8081 · api http://localhost:8080 · postgres localhost:5432
docker compose down -v   # also drops the DB volume, so the seed runs again next time
```

> Docker was not available in the Sprint 0 build environment, so the images and compose stack **have not been built or run yet**. The DB init script logic was exercised against a local PostgreSQL.
