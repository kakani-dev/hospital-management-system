# Microservices architecture

Status: **current development model** (decision 9 Oct 2026). Work on the monolith is on hold.
The approved plan is in `MICROSERVICES-PLAN.md`; database contracts are in `docs/contracts/db.md`.

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
| `backend/gateway/Hms.Gateway` | Legacy all-in-one host. On hold; it stays deployable until the Phase 1 cutover. |

`ArchitectureTests` enforce the boundaries: each service hosts exactly its own module, the edge
references only the platform, and only the legacy host references several modules.
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
- **Data access** keeps the existing pattern: `SET LOCAL ROLE authenticated` plus
  `request.jwt.claims` per transaction, so every RLS policy applies. Each service logs in as
  `hms_<svc>_login` (a member of `hms_svc_<svc>`) with about 5 pooled connections.
- **Cross-service reads** go only through published `*_v1` SECURITY DEFINER functions. Scheduling
  embeds `patient {id, mrn, firstName, lastName}` from `patient.patient_summary_v1`, with one call
  per page of at most 500 ids and no cross-schema join. Soft-deleted patients still embed as
  `null`, so the API contract is unchanged.
- **Outbox:** a single `messaging.outbox` table, where the database sets `source_service`. Only the
  scheduling login may act as `hms_dispatcher`. That dispatcher is off by default
  (`Outbox:Dispatcher:Enabled`). Identity mail uses a separate role, `hms_mailer`, and
  `Email:Dispatcher:Enabled` on the identity service only (off until `Smtp__Password` is set).
  The legacy host registers neither mailer nor an enabled dispatcher (B1).

## Local development and tests

- `docker compose up --build`: edge on :8080, services internal, web on :8081.
  `--profile monolith` adds the legacy host on :8090.
- Without Docker: `scripts/dev/run-microservices.sh` (see `docs/local-development.md`).
- API integration tests: `HMS_SYSTEM_TARGET=edge` (default, in-process edge plus the 3 services,
  each with its own login role) | `monolith` | `edge-url` (with `HMS_SYSTEM_BASE_URL`). Tests that
  need in-process hosts are tagged `[Trait("Mode","in-process-only")]`.
- CI (required check names unchanged):
  - **Backend** builds and unit-tests every project.
  - **SQL/RLS + integration** runs the migration chain check, then the SQL tests, then the API
    suite through the edge, then the API suite against the monolith on a fresh database.
  - **Playwright E2E** runs through the edge.
  - **Service images** builds and boots all five images, only when Docker-relevant files change.

## Phase 1 deploy (Azure Container Apps): what it needs

Nothing below has been done. **Each item needs Mohith's approval.**

1. **Database (hosted Supabase):**
   - Apply `20261012090000`, `20261012090100` (audit-tz, PR #4), then `20261013090000` and `20261013090100` (PR #5).
   - Create `hms_identity_login`, `hms_patients_login` and `hms_scheduling_login` out of band, each with a generated secret, and `grant hms_svc_<svc> to hms_<svc>_login`.
   - `20261013090100` removes `hms_dispatcher` from `hms_api`. Set `Outbox__Dispatcher__Enabled=false` on the live monolith **before** applying it.
2. **Azure resources:**
   - One Container Apps environment (Consumption, free monthly grant) and an image registry (ACR Basic, or GHCR).
   - Four apps. `edge` gets external ingress with min replicas 0 (or 1 to avoid cold starts). `identity`, `patients` and `scheduling` get internal ingress (environment only).
3. **Secrets** (Container Apps secrets or Key Vault):
   - The per-service `ConnectionStrings__HmsDatabase` through the Supavisor pooler.
   - `Edge__Key`, one random value shared by the edge and the services.
   - `Auth__Supabase__ProjectUrl`.
4. **Edge config:**
   - `ReverseProxy__Clusters__<svc>__Destinations__primary__Address=http://<svc>/` (internal FQDNs).
   - `Cors__AllowedOrigins` and `Cors__AllowedOriginPatterns` as above.
5. **Pool sizing:** 3 services × `Database__MaxPoolSize=5` per replica must fit the Supavisor limit alongside the monolith during the overlap.
6. **Cutover:**
   - Smoke test `/health/ready` and `/api/v1/warmup` on the edge URL, then run the E2E suite with `HMS_SYSTEM_TARGET=edge-url`.
   - Change Vercel `VITE_API_BASE_URL` to the edge URL and redeploy. Rollback means pointing it back at the monolith.
7. **CI/CD:** a deploy workflow (build, push, `az containerapp update`) with OIDC federated credentials. Creating the service principal or federated credential is also an Azure change.
