# Microservices architecture

Status: **current development model** (decision 9 Oct 2026). The all-in-one host is removed from
the repository. The App Service `medicore-hms-api` stays up until
`docs/runbooks/monolith-cutover.md`. The approved plan is in `MICROSERVICES-PLAN.md`; database
contracts are in `docs/contracts/db.md`; ownership is ADR 0002.

```text
browser (Vercel SPA) ──► edge (YARP, public)  /api/v1/*   one base URL, CORS, JWT, rate limits
                           │  X-Hms-Edge-Key + X-Request-Id, all client X-Hms-* headers stripped
                           ├──► identity    /me /tenants /branches /members /platform
                           ├──► patients    /patients
                           └──► scheduling  /practitioners /schedules /slots /appointments /queue
                                   │
                one Supabase Postgres: schema + group role per service, published *_v1 functions, one outbox
```

## Layout

| Project | Role |
|---|---|
| `backend/edge/Hms.Edge` | YARP gateway. References `Hms.Platform` only, never a module. |
| `backend/services/identity/Hms.Identity.Api` | Identity module host (port 8101 locally) |
| `backend/services/patients/Hms.Patients.Api` | Patients module host (8102) |
| `backend/services/scheduling/Hms.Scheduling.Api` | Appointments/queue module host (8103); the only outbox publisher |
| `backend/platform/Hms.Platform` | Shared plumbing: JWT, tenant resolution (`identity.my_tenant_grant_v1`), problem mapping, Npgsql (`No Reset On Close`, `Database:MaxPoolSize`), health, outbox, edge key, request id |
| `backend/tests/Hms.TestHost` | In-process composition for unit tests. Not a service, not an image, not deployed. |

`ArchitectureTests` enforce the boundaries: each service hosts exactly its own module, the edge
references only the platform, and no production host references more than one module.
`EdgeRouteCoverageTests` fail when a module serves an `/api/v1/<prefix>` the edge does not route
to the owning service.

## Edge behaviour (contract for the web app)

- **Paths are unchanged** (`/api/v1/*`) and there is a single base URL (`VITE_API_BASE_URL`).
- **CORS** is handled by the edge only (services send none). Allowed origins are
  `https://medicore-hms-three.vercel.app`, `http://localhost:5173` and `http://localhost:4173`, plus
  the project's preview pattern `https://medicore-hms-*-kakani-devs-projects.vercel.app`
  (`Cors:AllowedOrigins`, `Cors:AllowedOriginPatterns`). Exposed headers: `X-Hms-Tenant`,
  `X-Request-Id`, `Retry-After`. Preflight `Max-Age` is 600. CORS headers are also set on the edge's
  own 401/429/5xx responses.
- **Errors** are `application/problem+json` with a `code`:

  | Situation | Status | `code` | Headers |
  |---|---|---|---|
  | service cold or unreachable, `/health/ready` or warmup with a service down | 503 | `service_unavailable` | `Retry-After: 5` |
  | JWKS (signing keys) unreachable | 503 | `service_unavailable` | `Retry-After: 5` (never a misleading 401) |
  | upstream slower than 30 s (`ActivityTimeout`) | 504 | `upstream_timeout` | |
  | rate limited (per user `sub`, else IP; `RateLimiting:PermitPerMinute`) | 429 | `rate_limited` | `Retry-After` |
  | unknown `/api/v1/...` route | 404 | `not_found` | |
  | any `/internal/**` path (all methods, case and percent-encoding variants) | 404 | | |

- `GET /api/v1/warmup` is anonymous and rate-limited to 10/min per IP (`RateLimiting:WarmupPerMinute`).
  It pings every service's `/health/ready` and returns 200, or 503 with the list of services.
- `GET /health/live` reports the edge itself. `GET /health/ready` aggregates all services.
- `X-Request-Id` is accepted (`[A-Za-z0-9._:-]{1,64}`) or generated, forwarded and echoed.
  `X-Hms-Tenant` from a service is passed through to the browser.
- The edge validates the JWT, so a 401 never costs a service round trip and rate limits are per
  user. Each service validates it again.

## Services

- **No direct access.** When `Edge:Key` is set, every request except `/health*` without a matching
  `X-Hms-Edge-Key` gets a bare 404. In Azure the services also get internal-only ingress.
- **Tenant resolution** happens per request in each service via `identity.my_tenant_grant_v1`, not
  at the edge.
- **Data access:** each service logs in as `hms_<svc>_login` (a member of `hms_svc_<svc>`, about 5
  pooled connections) and, per transaction, `SET LOCAL ROLE hms_svc_<svc>` plus `request.jwt.claims`.
  That role's grants cover its own schema and approved `_v1` functions only. RLS policies include the
  service role. It is not a member of `authenticated`. See ADR 0002.
- **Cross-service reads** go only through published `*_v1` SECURITY DEFINER functions. Scheduling
  embeds `patient {id, mrn, firstName, lastName}` from `patient.patient_summary_v1`, with one call
  per page of at most 500 ids and no cross-schema join. Soft-deleted patients still embed as
  `null`, so the API contract is unchanged.
- **Outbox:** a single `messaging.outbox` table, where the database sets `source_service`. Only the
  scheduling login may act as `hms_dispatcher`. That dispatcher is off by default
  (`Outbox:Dispatcher:Enabled`). Identity mail uses a separate role, `hms_mailer`, and
  `Email:Dispatcher:Enabled` on the identity service only (off until `Smtp__Password` is set).
  Invite sign-in codes are one of those emails. Turning a checked code into a session also needs
  `Auth__Supabase__ServiceRoleKey` on identity only.
  The scheduling dispatcher stays off (B1). The App Service must stay off too until it is stopped.

## Local development and tests

- `docker compose up --build`: edge on :8080, services internal, web on :8081.
- Without Docker: `scripts/dev/run-microservices.sh` (see `docs/local-development.md`).
- API integration tests: `HMS_SYSTEM_TARGET=edge` (default, in-process edge plus the 3 services,
  each with its own login role) or `edge-url` (with `HMS_SYSTEM_BASE_URL`). Tests that
  need in-process hosts are tagged `[Trait("Mode","in-process-only")]`.
- CI (required check names unchanged):
  - **Backend** builds and unit-tests every project.
  - **SQL/RLS + integration** runs the migration chain check, the schema-ownership check, the SQL
    tests, then the API suite through the edge.
  - **Playwright E2E** runs through the edge.
  - **Service images** builds and boots the four images (edge, identity, patients, scheduling),
    only when Docker-relevant files change.

## Deploy

The live path is `docs/deploy.md` (Azure Container Apps). It does not deploy, restart, or
reconfigure `medicore-hms-api`, and it refuses to deploy if that app's outbox dispatcher is on.
Pointing the web app at the edge, applying `20261022140000`, and stopping the App Service are
separate approvals in `docs/runbooks/monolith-cutover.md`. This repository change does none of those.
