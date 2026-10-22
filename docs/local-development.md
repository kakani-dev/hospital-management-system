# Local development guide

## Prerequisites

| Tool | Version used | Notes |
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

- `supabase/scripts/local-supabase-shim.sql` creates the `anon`, `authenticated`, `service_role` and `supabase_auth_admin` roles, plus `auth.users`, `auth.uid()` and `auth.jwt()`, **only when they don't already exist**. Never run it against a hosted Supabase project.
- `supabase/scripts/local-api-login-role.sql` creates the local API login role `hms_api_login` (password `hms_api_local_only`, **local/CI throwaway databases only**) and grants it `hms_api`. On a hosted project, create the login role out-of-band with a generated password (see [docs/sprint-1-report.md](sprint-1-report.md)).
- `SKIP_SQL_TESTS=1 TEST_DB=hms_e2e bash supabase/scripts/run-sql-tests.sh` (or `npm run e2e:db`) prepares a database without running the SQL tests.
- On a real Supabase project, apply `supabase/migrations` with `supabase db push`, or let the Supabase GitHub integration do it. Expose the `identity` and `patient` schemas in API settings only if PostgREST access is wanted. The migrations themselves contain no `auth` stand-ins; Supabase already provides `auth.users`, `auth.uid()`, `auth.jwt()` and the roles.
- Seeding a hosted project (synthetic data only): run `supabase/scripts/hosted-auth-users.sql` first (it creates the 7 demo users with the extra columns GoTrue needs, **without passwords**, so nobody can sign in as them), then `supabase/seed.sql`.
- If migrations were applied through the Supabase dashboard/MCP instead of the CLI, the remote migration history uses the apply time as version, not the file timestamp. Run `supabase migration repair` before the first `supabase db push` so the CLI does not try to re-apply them.
- SQL tests impersonate users the way PostgREST does: `set local role authenticated` plus `request.jwt.claims` (see `supabase/tests/00_test_helpers.sql`).

## 2. Backend

```bash
dotnet build backend/Hms.slnx
dotnet test backend/Hms.slnx --filter "Category!=Database"     # unit tests, no DB needed
dotnet test backend/Hms.slnx --filter "Category=Database"      # integration (real JWT + HTTP) + RLS DB tests;
                                                                 # needs the hms_sql_test DB from step 1

# The API connects as the low-privilege login role; RLS applies to every query.
export ConnectionStrings__HmsDatabase="Host=localhost;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only"
# Either a real Supabase project (JWKS over https) ...
export Auth__Supabase__ProjectUrl="https://<project-ref>.supabase.co"
# ... or the local mock auth server (npm run mock-auth, http://localhost:54321):
#   export Auth__Supabase__ProjectUrl=http://localhost:54321 Auth__Supabase__AllowInsecureHttp=true
dotnet run --project backend/gateway/Hms.Gateway                 # http://localhost:8080
curl localhost:8080/health/ready
open http://localhost:8080/swagger
```

Configuration (environment variables use `__` for nesting):

| Key | Purpose |
|---|---|
| `ConnectionStrings__HmsDatabase` | Npgsql connection string |
| `Auth__Supabase__ProjectUrl` | `https://<ref>.supabase.co`. If empty, every bearer token is rejected. JWKS: `<url>/auth/v1/.well-known/jwks.json` |
| `Auth__Supabase__Audience` | default `authenticated` |
| `Auth__Supabase__LegacyJwtSecret` | optional HS256 legacy secret (secret store only, never in git) |
| `Auth__Supabase__AllowInsecureHttp` | `true` only for local mock auth/tests; refused in Production |
| `Cors__AllowedOrigins__0..n` | Allowed SPA origins |
| `RateLimiting__PermitPerMinute` | Per user/IP fixed window (default 120) |
| `OpenApi__Enabled` | Swagger/OpenAPI outside Development |

Protected endpoints need a valid Supabase access token (see [auth-flow.md](auth-flow.md)). Locally, get one from the mock auth server:

```bash
npm run mock-auth   # MOCK_AUTH_DB_URL defaults to .../hms_e2e; password: synthetic-demo-pass
curl -s -X POST 'http://localhost:54321/auth/v1/token?grant_type=password' \
  -H 'content-type: application/json' -d '{"email":"admin@alpha.example","password":"synthetic-demo-pass"}'
```

## 3. Frontend

```bash
cp apps/web/.env.example apps/web/.env.local   # set VITE_SUPABASE_URL + VITE_SUPABASE_PUBLISHABLE_KEY (public values only)
npm --prefix apps/web ci
npm --prefix apps/web run dev            # http://localhost:5173 (proxies /api and /health to :8080)
npm --prefix apps/web run lint
npm --prefix apps/web run test
npm --prefix apps/web run build
```

Sign-in uses Supabase Auth (`@supabase/supabase-js`). Without `VITE_SUPABASE_URL` and a publishable/anon key, the login page says authentication isn't configured. For local work against the mock server, use `VITE_SUPABASE_URL=http://localhost:54321` with any placeholder key, and the synthetic seed users (e.g. `admin@alpha.example`, `consultant@shared.example`) with the password `synthetic-demo-pass`. **Never put a service-role/secret key in a `VITE_*` variable.**

## 4. End-to-end tests

```bash
npm ci && npm --prefix apps/web ci
npx playwright install --with-deps chromium   # or without --with-deps if system libs exist
npm run e2e:db                                # throwaway hms_e2e DB: migrations + synthetic seed + hms_api_login
npm run e2e                                   # starts mock auth (:54321), the API (:8080) and the web preview (:4173)
```

The suite is full-stack: the mock GoTrue server issues ES256 tokens using the real access token hook, the API validates them through the mock's JWKS and queries Postgres as `hms_api_login`, and the web preview proxies `/api` to the API. Locally, already-running servers are reused. Run `npm run e2e:db` again for a clean database. `E2E_API_COMMAND` can point at a prebuilt gateway binary (Jenkins uses this).

## 5. Docker Compose

```bash
docker compose up --build
# web http://localhost:8081 · api http://localhost:8080 · postgres localhost:5432
docker compose down -v   # also drops the DB volume, so the seed runs again next time
```

Set `HMS_AUTH_URL` (and `HMS_AUTH_ALLOW_HTTP=true` for the mock), plus `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`, before `docker compose up` to enable sign-in. The API connects as `hms_api_login`, which the DB init script creates.

> Docker was not available in the Sprint 0/1 build environment, so the images and compose stack **have not been built or run yet**. The DB init script logic was exercised against a local PostgreSQL.

### Microservices (default)

`docker compose up --build` runs the YARP edge on http://localhost:8080 (the only published API port)
in front of identity, patients and scheduling. Each service logs in with its own role
(`hms_<svc>_login`, `supabase/scripts/local-api-login-role.sql`) and answers 404 to anything that does
not come through the edge (`X-Hms-Edge-Key`). The legacy monolith is opt-in:
`docker compose --profile monolith up --build` (http://localhost:8090).

Without Docker:

```bash
HMS_MS_DB="Host=localhost;Port=5432;Database=hms" \
ASPNETCORE_ENVIRONMENT=Development \
Auth__Supabase__ProjectUrl=http://localhost:54321 Auth__Supabase__AllowInsecureHttp=true \
  bash scripts/dev/run-microservices.sh      # edge :8080 (API_PORT), services :8101-8103
curl localhost:8080/health/ready             # 200 once all three services are ready
```

Playwright (`npm run e2e`) starts the same script and waits on the edge's `/health/ready`;
`E2E_API_COMMAND` overrides it (e.g. the monolith). API integration tests pick the system under test
with `HMS_SYSTEM_TARGET=edge` (default: in-process edge + 3 services) | `monolith` | `edge-url`
(+ `HMS_SYSTEM_BASE_URL`). See `docs/architecture/microservices.md`.

## 6. Cleaning build artifacts

```bash
npm run clean        # = scripts/clean.sh
npm run clean:all    # also removes node_modules (then rerun npm ci / npm run web:install)
```

`scripts/clean.sh` removes `apps/web/dist`, `coverage`, `.vite` caches and `*.tsbuildinfo`, plus Playwright's `test-results`, `playwright-report` and `blob-report`. It also runs `dotnet clean backend/Hms.slnx` and deletes every `bin/`, `obj/` and `TestResults/` under `backend/`. `node_modules` is only touched with `--all`. All of these paths are git-ignored, and nothing built is committed.

CI housekeeping: every `actions/upload-artifact` step sets `retention-days: 7`. `.github/workflows/cleanup.yml` runs weekly and on demand. It deletes artifacts older than 7 days and caches unused for 7 days, deletes Azure Container Registry `sha-` tags beyond the 10 newest per service (never a tag that is deployed), and deactivates inactive Container Apps revisions outside the newest three (never the revision that has traffic). See [deploy.md](deploy.md). Jenkins keeps 10 builds and the artifacts of 5 (see [infra/jenkins/README.md](../infra/jenkins/README.md)).
