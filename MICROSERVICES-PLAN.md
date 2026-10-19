# MediCore HMS: moving from a modular monolith to microservices (plan only)

Author: CTO office, 9 Oct 2026 (IST). Status: **APPROVED by Mohith on 9 Oct 2026 (IST)**, with the shape in
§0.1 below (that section overrides anything in the rest of the plan that differs). Phase 0 is built on branch
`ms/phase0` (draft PR into `main`). Nothing has been deployed, and no Azure, Supabase, Render or Vercel
resource has been changed.

Inspected: `/workspace/hms-wt/s2-integration` @ `77b34f2` (Sprint 2 + PR #2 review fixes) and
`/workspace/hospital-management-system` (main @ `3a81224`).

---

## 0. TL;DR

| Decision | Recommendation |
|---|---|
| Services | **4 services + 1 edge**: `identity`, `patients`, `scheduling` (practitioners, schedules, slots, appointments, OPD queue), `notifications` (first event consumer, built when a feature needs it), plus `edge` (YARP gateway/BFF). |
| Data | **Keep ONE Supabase Postgres** with one schema per service (as today). Each schema has one owner, and there is one migration chain. Splitting databases would break RLS, which depends on `identity.*` helpers 51 times, and the cross-schema FKs. On the Supabase free tier it would also cost a second project. |
| Sync traffic | Browser → `edge` → one service. **No service-to-service HTTP calls on the request path**. Cross-service reads go through published SQL views/functions in the same DB. |
| Async traffic | The existing **transactional outbox** (`messaging.outbox`, filled by DB triggers, read by the `hms_dispatcher` lease dispatcher). The publisher pushes over HTTP to consumers now. A broker (Service Bus) comes only when needed. |
| Auth | Forward the user's Supabase JWT unchanged. Edge validates it (cheap reject + rate limit). **Every service re-validates it** and resolves the tenant itself through a shared `Hms.Platform` library, so RLS through `hms_api_login` works exactly as today. |
| Web | `VITE_API_BASE_URL` points at the edge and never changes again. CORS, `X-Hms-Tenant` exposure, rate limits and security headers live at the edge. |
| Migration | Strangler: edge in front of the monolith first, then extract **patients → scheduling → identity**. The monolith is the catch-all route until it is empty. The route flip in the edge config is the rollback. |
| Free hosting | **Azure Container Apps (Consumption), Central India**, scale-to-zero, internal ingress for services. It costs $0 inside the monthly free grant (≈200 replica-hours at 0.25 vCPU/0.5 GiB). Stopgap: extra apps in the existing F1 plan (max 10 apps). |
| Cheapest paid | **App Service B1 Linux, Central India, one plan hosting all 5 apps: $0.018/h ≈ $13.14/month (₹1.7278/h ≈ ₹1,261/month)**. It has Always On, so there are no cold starts and the dispatcher keeps running. |
| Effort | **≈ 23–31 dev-days** for phases 0–6 (≈ 20–26 without the optional Phase 5 notifications/broker); detail in §12. |

Honest framing: this is "microservices with a shared database" (separately deployable services, owned schemas,
one Postgres). That is the right trade-off at our size and on free tiers. Full database-per-service is listed as a later option with
its real cost (§3.3).

---

## 0.1 Decision (approved by Mohith, 9 Oct 2026 IST)

| Item | Decision |
|---|---|
| Services | **3 services + YARP edge**: `identity`, `patients`, `scheduling` (practitioners, schedules, appointments, OPD queue), plus `edge` (YARP). `notifications` is **dropped from this migration** and will be added later, as an outbox consumer, when a feature needs it. |
| Data | **One Supabase Postgres**, schema per service, cross-schema reads only through versioned (`_v1`) published views/functions (`docs/contracts/db.md`). |
| Hosting | **Azure Container Apps, Consumption plan, free grant** (Central India). App Service B1 (about $13.14/mo) stays the paid fallback, and needs separate approval. |
| Timing | Done **before Sprint 3** starts. Sprint 3 features are built in the services, not in the monolith. |
| Phase 0 (no runtime change) | `Hms.Platform` shared library, published cross-schema contracts, Dockerfile fix, per-service Dockerfiles, compose skeleton, CI. Status: **built on `ms/phase0`, draft PR open**. |
| Still needs Mohith's OK | Creating Azure resources (Container Apps environment, apps), applying migrations to hosted Supabase, and changing Vercel `VITE_API_BASE_URL` to the edge. |

## 1. What the code looks like today (inspected)

**Host and modules** (`backend/`, .NET 10, ~4.8k lines non-test C#)

| Project | Role | Notes |
|---|---|---|
| `gateway/Hms.Gateway` | The single ASP.NET host (the monolith). Despite the name, it is not a reverse proxy. | Serilog JSON, JWT (Supabase JWKS), rate limiter by `sub`, CORS, `UseTenantResolution()`, health `/health/live`, `/health/ready`, all endpoints under `/api/v1`, `AddHmsOutboxDispatcher`. |
| `modules/Identity` | `/me`, `/me/context`, `/me/invitations`, `/tenants/current`, `/branches`, `/members` | Owns `TenantResolutionMiddleware`, `IMembershipStore`, `ClaimsTenantResolver`. **Every request in every module depends on it.** |
| `modules/Patients` | `/patients` (list, search, duplicates, get, create, patch, delete, restore) | `PatientsDbContext` (schema `patient`), registry SQL functions. |
| `modules/Appointments` | `/practitioners`, `/schedules`, `/slots`, `/appointments` (+ reschedule/cancel/no-show/check-in), `/queue` (+ walk-in, status) | `AppointmentsDbContext` (schema `appointment`). **Also maps `patient.patients` as `PatientRef`** (read-only LEFT JOIN embedding, `PatientEmbedding.cs`). |
| `shared/Hms.SharedKernel` | Tenancy (`TenantContext`, roles, headers), persistence (`DbSessionContext`, `RlsTransactionInterceptor`, audit/tenant interceptors), HTTP helpers, `OutboxDispatcher` | csproj comments already enforce "modules depend only on the shared kernel". |

Module boundaries are already clean at the C# level: no module references another, and there are no in-process calls between modules.
**The coupling is in the database**, so the database plan matters most.

**Database (`supabase/migrations`, 15 files)**: schemas `identity`, `patient`, `appointment`, `messaging`, `audit`.

Cross-schema dependencies found:

| Dependency | Where |
|---|---|
| FKs to `identity.tenants` / `identity.branches` | `patient.patients`, every `appointment.*` table, `appointment.queue_*` |
| FKs `appointment.appointments` / `queue_entries` → `patient.patients` | `20261010090100`, `20261010090200` |
| RLS helpers `identity.has_tenant_role` (27 uses), `identity.can_access_branch` (14), `identity.current_tenant_ids` (10) | RLS policies and functions in `patient` and `appointment` |
| `patient.soft_delete_patient` **reads `appointment.appointments` and `queue_entries`** (blocks delete while a visit is active) | `20261010090000` lines ~100–105. This is a reverse dependency, patients → scheduling. |
| `audit.stamp_audit_columns`, `audit.prevent_tenant_change`, `audit.log_row_change` | Triggers on all business tables |
| Outbox | `messaging.outbox` is written only by triggers (`appointment.emit_appointment_event`, `emit_queue_event`). Its `aggregate_type` is constrained to `appointment`/`queue_entry`. Events: `appointment.booked`, `appointment.rescheduled`, `queue.token_issued`, `queue.status_changed`. |

**Auth chain.** The SPA signs in with Supabase Auth, and the custom access-token hook adds `tenant_id`/`branch_id`. The API validates the JWT
(ES256/RS256 via JWKS, issuer `<project>/auth/v1`, audience `authenticated`, `role` must be `authenticated`).
`TenantResolutionMiddleware` then checks the active membership (1–2 DB transactions) and fills `TenantContext` + `DbSessionContext`. On every EF
transaction, `RlsTransactionInterceptor` runs `set_config('role','authenticated')` and `request.jwt.claims` (transaction-local,
which works through Supavisor :6543). The login role `hms_api_login` is NOINHERIT and owns nothing (fail closed).

**Outbox dispatcher.** `OutboxDispatcher` is a `BackgroundService`, off unless `Outbox:Dispatcher:Enabled=true`. It claims rows with
`messaging.claim_outbox` (FOR UPDATE SKIP LOCKED + lease) as `SET LOCAL ROLE hms_dispatcher`, then `complete_outbox`/`fail_outbox`
with exponential back-off. It is at-least-once with an in-memory dedupe set. The publisher is `LoggingOutboxPublisher` (log only). **No consumer
exists yet.** Several instances may run safely.

**Other findings while inspecting** (independent of this decision):
- `infra/docker/api.Dockerfile` copies the Identity and Patients csproj files before `dotnet restore`, **but not Appointments**. So the Docker image build
  (compose / Render) very likely fails on Sprint 2. The Azure deploy used a zip deploy, so it wasn't affected. This gets fixed in Phase 0.
- DevOps added `No Reset On Close=true` only to the Azure connection string (the DISCARD ALL hang through Supavisor). Every new service needs
  it, so it belongs in code (Phase 0).

---

## 2. Service boundaries

| Service | Owns (schema / tables) | Public routes (via edge) | Emits | Consumes |
|---|---|---|---|---|
| **identity** | `identity.*` (tenants, branches, memberships, user_profiles, invites), the Supabase access-token hook, RLS helper functions | `/api/v1/me*`, `/api/v1/tenants/*`, `/api/v1/branches*`, `/api/v1/members*` | (later) `membership.*`, `branch.*` | nothing |
| **patients** | `patient.*` (patients, phone normalisation, duplicates, soft delete/restore) | `/api/v1/patients*` | (later) `patient.registered`, `patient.updated`, `patient.deleted` | nothing |
| **scheduling** | `appointment.*` (practitioners, schedules, slots, appointments, queue, state machine) **and the outbox dispatcher** | `/api/v1/practitioners*`, `/schedules*`, `/slots*`, `/appointments*`, `/queue*` | `appointment.*`, `queue.*` (existing) | (later) `patient.deleted` |
| **notifications** (new, built when Sprint 3+ needs reminders/SMS) | `notification.*` (templates, deliveries, idempotency keys) | none at first (internal only) | `notification.sent/failed` | `appointment.booked/rescheduled/cancelled`, `queue.token_issued` |
| **edge** (YARP BFF) | no data | everything under `/api/v1`, `/health/*` | none | none |

Why appointments and queue stay together: check-in (`appointment.check_in`) and queue status sync
(`set_queue_status` ↔ appointment status, plus the PR #2 MAJ-1 fix `cancel_queue_entry_for_appointment`) are **single DB transactions
over both tables**. Splitting them would turn a correct atomic operation into a saga, with no benefit.

Why not more services (billing, pharmacy, labs, EMR): they don't exist yet. Each new domain becomes its own service when its sprint starts,
using the same template.

---

## 3. Data ownership

### 3.1 Recommendation: one Supabase Postgres, a schema per service, enforced ownership

Rules:
1. **One owner per schema.** Only the owning service's code and migrations create or alter objects in it.
2. **No cross-schema writes, ever.** Another service's data changes only through that owner's API or events.
3. **Cross-schema reads only through a published, versioned SQL surface.** Views or `SECURITY INVOKER`/`DEFINER` functions are
   named in `contracts/db/<schema>.md`. Concretely:
   - `patient.patient_summary_v1` (id, tenant_id, display name, MRN, deleted flag), `security_invoker = true` so RLS still applies.
     It replaces the `PatientRef` mapping of `patient.patients` inside `AppointmentsDbContext`.
   - `appointment.patient_has_open_visits_v1(patient_id uuid) returns boolean` is published by scheduling. It replaces the direct reads
     of `appointment.appointments`/`queue_entries` inside `patient.soft_delete_patient`.
   - `identity.has_tenant_role`, `can_access_branch`, `current_tenant_ids`, `my_memberships`, `my_active_context` are already the
     identity service's published authorisation API. They are frozen as `v1` and changed only additively.
4. **FKs to `identity.tenants`/`branches` and from scheduling → `patient.patients` stay.** They are cheap, correct integrity
   guarantees, and they are the main reason to keep one database. They are documented as contracts. A patient is soft-deleted (never hard-deleted),
   so the `on delete restrict` FK never fires in normal operation.
5. **One migration chain** (`supabase/migrations`) stays, because ordering across schemas matters (FKs, helpers). Ownership is by file
   naming (`<ts>_<service>_<what>.sql`) and a CODEOWNERS-style CI check that a migration touches only its own schema.
   The exceptions are an explicit `-- cross-schema: approved` header and a reviewer from the other team.

### 3.2 DB roles per service

| Phase | Setup |
|---|---|
| Phases 1–4 (same as today) | Each service gets its **own login role**: `hms_identity_login`, `hms_patients_login`, `hms_scheduling_login`. Each is NOINHERIT, owns nothing, and is granted `hms_api` (so it can `SET ROLE authenticated`). This gives per-service connection strings, per-service revocation, `pg_stat_activity` attribution and pooler accounting. Isolation of data is still enforced by RLS + ownership rules, because every service runs as `authenticated`, as today. |
| Phase 6 hardening (optional) | Per-service "session" roles (`hms_svc_patients`, …) that are **not** members of `authenticated`, with grants only on the owner's schema plus EXECUTE on the published functions. Policies change from `to authenticated` to `to authenticated, hms_svc_<x>`. This makes "patients cannot even read `appointment.*` except through the published function" a DB guarantee rather than a code rule. It is a sizeable migration (every policy) and it overlaps with the deferred DB-hardening backlog (`docs/backlog/pr1-db-hardening-draft.sql`), so do the two together. |
| Dispatcher | `hms_dispatcher` stays as is. The scheduling login gets `grant hms_dispatcher`. |

### 3.3 Why not split databases (and what it would cost)

- RLS on `patient`/`appointment` calls `identity.*` functions 51 times. In separate databases, each would need a replicated copy of
  memberships/branches (logical replication or event-fed tables) and re-written policies. That is a large security-sensitive rewrite while
  PR #1/#2 hardening is still pending.
- Cross-DB FKs disappear. Patient-in-tenant, branch-in-tenant and active-visit checks become eventually consistent sagas.
- Supabase Auth (GoTrue) and the access-token hook live in one project. Other projects would only validate JWTs, which works, but the hook can only read
  its own project's `identity` schema.
- Cost: the free plan Nano instance is per project. Supabase's docs list Micro at ~$10/month per extra project on paid orgs, plus the paid org plan itself
  (not costed here, see supabase.com/pricing).
- Revisit when a single domain needs a different scale or retention, or a regulated-data boundary (e.g., EMR) requires physical separation.

### 3.4 Connection budget (real limit on the free tier)

Supabase Nano/Micro: **60 DB connections, 200 pooler clients** (Supabase compute docs). With 3–4 services each holding an Npgsql pool
through Supavisor :6543: set `Maximum Pool Size=10`, `No Reset On Close=true` and `Minimum Pool Size=0` in each service. Then 4 × 10 = 40 pooler
clients, which is fine. The outbox dispatcher's separate `NpgsqlDataSource` (review nit: it is always opened, even when disabled) should
only be built when enabled.

---

## 4. Communication

### 4.1 Synchronous (HTTP)

- Browser → **edge** → exactly one service. The edge does path-based routing only (table in §5).
- **No synchronous service-to-service calls on the request path.** Today there are none, because the modules never call each other. The three
  cross-module data needs are covered by the DB contracts in §3.1. This avoids chained cold starts on free tiers and cascading failures.
- If a synchronous call is ever unavoidable, it uses a typed `HttpClient` with `Microsoft.Extensions.Http.Resilience` (timeout 3 s, 2 retries
  on idempotent GETs only, circuit breaker), forwards the user's JWT, and is listed in `contracts/http/dependencies.md`.

### 4.2 Asynchronous (events via the outbox)

Keep the current design, which is already microservice-grade: trigger-written outbox, same transaction as the change, lease-based claim, at-least-once delivery.

Changes:
1. **Generalise `messaging.outbox`.** Add `source_service text not null`. Widen the `aggregate_type` check (add `patient`, `membership`),
   add `traceparent text` (trace propagation) and `schema_version int not null default 1`. `claim_outbox` gets a `p_source` filter so each
   producing service dispatches only its own events. Patients/identity triggers can then emit too.
2. **Dispatcher placement.** It runs inside each **producing** service (`scheduling` now, then `patients`/`identity` when they emit). It already
   tolerates several instances.
3. **Publisher.**
   - *Now (free):* `HttpOutboxPublisher` POSTs the envelope to each subscriber's internal endpoint (`POST /internal/events`). Subscribers come from config
     (`Outbox:Subscribers:<eventType>`). Auth is an internal key header plus caller identity (ACA internal ingress or App Service access restrictions).
     Consumers dedupe on `event_id` in their own `<schema>.inbox` table (unique `event_id`, insert-first idempotency), replacing the
     in-memory set.
   - *Later (when there are ≥2 consumers per event or bursts):* Azure Service Bus. Basic tier is **₹4.80 per million operations**
     (retail API, Central India) but has queues only. Topics (fan-out) need Standard, which is not costed here. Do not add it before it is needed.
4. **Envelope contract** (`contracts/events/envelope.v1.json`): `event_id, event_type, schema_version, tenant_id, aggregate_type,
   aggregate_id, occurred_at, traceparent, payload`. Payloads stay **ID/status/time only (no names/phones/reasons)**. Code Review
   flagged that patient id + visit time is still PHI-adjacent, so consumers are treated as PHI systems (HTTPS only, no payload logging, retention
   limit on `messaging.outbox` done rows, e.g., 30 days, and on inboxes).
5. **Scale-to-zero caveat.** On F1 (no Always On) and on ACA with min replicas 0, the dispatcher sleeps with its host. Events wait in the
   outbox until the next request wakes the service. Nothing is lost, only delayed. That is fine while the publisher is log-only and reminders aren't built.
   For ACA, an optional KEDA `postgresql` scale rule on `select count(*) from messaging.outbox where status='pending'` wakes the dispatcher
   when needed. That needs a tiny read-only count function for the scaler role.

---

## 5. Edge: API gateway / BFF (YARP)

New project `backend/edge/Hms.Edge` (ASP.NET + `Yarp.ReverseProxy`). It is deployed under the URL the web app already uses (§12, Phase 1).

Responsibilities (moved out of the current host):
- CORS (`Cors:AllowedOrigins`, exposes `X-Hms-Tenant`), security headers, forwarded headers, request size limits.
- JWT validation (same `AuthenticationSetup` code from `Hms.Platform`), **rate limiting by `sub`**, before proxying.
- Routing (config, not code, so a route flip is a config change and a restart):

| Path prefix | Cluster |
|---|---|
| `/api/v1/patients` | patients |
| `/api/v1/practitioners`, `/schedules`, `/slots`, `/appointments`, `/queue` | scheduling |
| `/api/v1/me`, `/tenants`, `/branches`, `/members` | identity |
| `/api/v1/{**catch-all}` | **legacy monolith** (until Phase 6) |
| `/internal/**` | **blocked at the edge** (404) |

- `/health/live` (self), `/health/ready` (self + `GET /health/ready` on each cluster, 2 s timeout). OpenAPI: proxies each service's
  `/openapi/v1.json` and serves a merged Swagger UI in non-production.
- It forwards `Authorization`, `traceparent`, `X-Request-Id`, and adds `X-Hms-Edge-Key` (secret) and `X-Forwarded-*`. It strips any client-sent
  `X-Hms-*` request headers.
- It holds no business logic and does not call the DB. Tenant resolution stays in the services (next section), so the edge adds no DB
  round-trip.

---

## 6. Auth propagation

1. The browser sends `Authorization: Bearer <Supabase access token>` to the edge (unchanged).
2. The edge validates signature/issuer/audience/expiry/`role=authenticated` and rejects early (401) or rate-limits. It **forwards the same
   token unchanged**. No internal token minting: one less signing key to manage, and services see the real user.
3. Each service runs the same pipeline as today from `Hms.Platform`: `AddHmsAuthentication` (JWKS, cached per process) →
   `UseTenantResolution` → `DbSessionContext` → `RlsTransactionInterceptor`. **RLS stays the final authority**, so a mis-routed or forged
   request still can't cross tenants.
4. Tenant resolution moves from the Identity module to `Hms.Platform`. Its `IMembershipStore` implementation calls the published
   `identity.my_active_context()` / a new `identity.resolve_grant_v1(tenant, branch)` function over plain Npgsql instead of
   `IdentityDbContext`, so no service needs identity's EF model.
5. Services are not publicly trusted:
   - **ACA:** services use **internal ingress**, reachable only from the edge inside the environment.
   - **App Service:** services stay public (`*.azurewebsites.net`). Access restrictions on the edge's outbound IPs alone are not enough, because F1/B1
     outbound IPs are shared with other customers on the stamp. So each service **also** requires the `X-Hms-Edge-Key` header (constant-time
     compare, secret in app settings) **and** still validates the JWT.
6. Events have no user. Consumers act as a system principal with their own role and narrow grants. `tenant_id` comes from the
   envelope and is pinned via `set_config('request.jwt.claims', ...)` on a service role whose policies allow only that consumer's tables.
7. Supabase JWT key rotation: unchanged (ConfigurationManager refreshes on unknown `kid`). Each service fetches JWKS itself. That is a few
   requests per hour per service, which is negligible.

---

## 7. Shared contracts and libraries

| Package (monorepo project refs, no NuGet feed needed yet) | Contents | Rule |
|---|---|---|
| `backend/platform/Hms.Platform` (from `Hms.SharedKernel` + `Hms.Gateway/Infrastructure`) | AuthN setup, tenant resolution, `DbSessionContext`, RLS/audit/tenant interceptors, `HmsProblems`, `BranchScope`, health checks, Serilog + OpenTelemetry "service defaults", outbox store/dispatcher/publishers, edge-key middleware | Infrastructure only, **no domain types**. Changes need the full CI matrix. |
| `backend/contracts/Hms.Contracts.Events` | Envelope + one record per event type, versioned (`AppointmentBookedV1`), and JSON Schemas in `contracts/events/*.json` generated from them | Additive changes only. Breaking = new `V2` + dual-publish for one release. |
| Per-service HTTP contracts | Stay inside each service (DTOs, validators). Each service publishes `openapi/v1.json`. | CI snapshots the OpenAPI per service and fails on a breaking diff (removed field/route, type change) unless the PR is labelled `api-breaking`. |
| `contracts/db/*.md` | The published SQL surface per schema (§3.1) | SQL tests assert these objects exist with these signatures. |

Web client: `apps/web/src/lib/api/client.ts` keeps one base URL. Optionally generate TS types from the merged edge OpenAPI later.

---

## 8. Repo layout (monorepo stays)

```
backend/
  Hms.slnx
  Directory.Build.props / Directory.Packages.props / global.json   (unchanged, central package versions)
  edge/Hms.Edge/                         YARP gateway/BFF
  services/
    identity/Hms.Identity.Api/           host (Program.cs) + endpoints + IdentityDbContext
    identity/Hms.Identity.Tests/
    patients/Hms.Patients.Api/
    patients/Hms.Patients.Tests/
    scheduling/Hms.Scheduling.Api/       practitioners, schedules, slots, appointments, queue, dispatcher
    scheduling/Hms.Scheduling.Tests/
    notifications/Hms.Notifications.Api/ (Phase 5)
  platform/Hms.Platform/
  contracts/Hms.Contracts.Events/
  legacy/Hms.Monolith/                   today's Hms.Gateway host, shrinking; deleted in Phase 6
  tests/
    Hms.DatabaseTests/                   unchanged (DB is shared)
    Hms.ContractTests/                   OpenAPI snapshots, event schema tests, published-SQL-surface tests
    Hms.SystemTests/                     today's 172 integration tests, run through the edge (see §9)
contracts/events/*.json, contracts/db/*.md
infra/docker/service.Dockerfile          one parameterised Dockerfile (ARG SERVICE) - fixes the missing-Appointments bug
infra/azure/                             Bicep or az CLI scripts per hosting option (no portal-only state)
supabase/migrations/                     single chain, <ts>_<service>_<what>.sql
apps/web/                                unchanged
```

During Phases 2–4 each service's endpoint code is **moved** (git mv) from `modules/<X>` into `services/<x>`, not copied. The legacy host
references the service project as a library until its route is flipped, so there is never a second copy of the business logic.
Each service project exposes `AddXxxService()` / `MapXxxService()`. Its own `Program.cs` and the legacy host both call them.

---

## 9. CI changes (`.github/workflows/ci.yml`)

Branch protection requires 4 checks today: *Frontend*, *Backend*, *SQL/RLS + integration*, *Playwright E2E*. Keep those **names stable** during
the migration so protection keeps working, and add one aggregate gate:

1. `changes` job (`dorny/paths-filter`): flags `web`, `edge`, `platform`, `contracts`, `svc-identity`, `svc-patients`, `svc-scheduling`,
   `migrations`. A change to `platform`/`contracts`/`migrations` turns on everything.
2. **Backend** becomes a matrix over `[edge, identity, patients, scheduling, legacy]`: build, unit tests, `docker build` with
   `infra/docker/service.Dockerfile`. This makes the image build a CI gate, which would have caught the Dockerfile bug. Skipped matrix legs report success.
3. **Contracts** (new, folded into *Backend*): OpenAPI snapshot diff per service, event JSON-schema validation, project-reference rule
   (services may reference only `Hms.Platform` and `Hms.Contracts.*`, never each other) as a unit test.
4. **SQL/RLS + integration**: unchanged DB/SQL tests, plus a migration-ownership lint. Integration tests run with
   `WebApplicationFactory` per service (each service's own tests), plus the existing 172 API tests as **system tests through the edge**. In CI the edge
   is hosted in-process with YARP pointing at in-process `TestServer`s. That keeps them fast and uses no Docker-in-Docker.
5. **Playwright E2E**: starts postgres + mock auth + **edge + all services** (`docker compose -f docker-compose.yml -f docker-compose.ci.yml up`) instead of
   one API. Time budget: today 7m13s. Expect +1–2 min for image builds, which layer caching mitigates.
6. `ci-gate` job `needs:` all of the above and is the one check to add to branch protection later.
7. **Deploy** (new `deploy.yml`, `workflow_dispatch` + on push to `main` per changed service). It builds the image, pushes to GHCR (public repo, so
   free), and deploys that one service. Gated by a GitHub environment `dev` with required reviewer = Mohith for the first weeks. No
   hosted DB migration runs from CI (stays runbook + approval, as today).
8. The Jenkinsfile mirror: same matrix, non-required, updated in Phase 1.

---

## 10. Local dev (docker compose)

```yaml
services:
  postgres:      # unchanged: supabase shim + migrations + seed; creates per-service login roles (local passwords)
  mock-auth:     # existing `npm run mock-auth` as a container (JWKS over http, AllowInsecureHttp only in Development)
  edge:          { build: { dockerfile: infra/docker/service.Dockerfile, args: { SERVICE: edge } }, ports: ["127.0.0.1:8080:8080"],
                   environment: { Routes__patients: http://patients:8080, Routes__scheduling: http://scheduling:8080,
                                  Routes__identity: http://identity:8080, Routes__legacy: http://legacy:8080 } }
  identity:      { ... SERVICE: identity,   ConnectionStrings__HmsDatabase: Host=postgres;Username=hms_identity_login;... }
  patients:      { ... SERVICE: patients,   Username=hms_patients_login }
  scheduling:    { ... SERVICE: scheduling, Username=hms_scheduling_login, Outbox__Dispatcher__Enabled: "true" }
  legacy:        { ... SERVICE: legacy }   # removed in Phase 6
  aspire-dashboard: { image: mcr.microsoft.com/dotnet/aspire-dashboard, ports: ["127.0.0.1:18888:18888"] }  # traces/logs/metrics UI (OTLP)
  web:           # unchanged; VITE_API_BASE_URL=http://localhost:8080 (the edge)
```

- Only the edge, web, postgres and the dashboard publish ports on 127.0.0.1. Services are reachable only on the compose network (mirrors ACA
  internal ingress).
- `npm run dev:api` (no Docker) runs `Hms.Monolith` (legacy host), which composes all services in one process. It stays useful for fast
  debugging, and at the end of Phase 6 it becomes the **"all-in-one" host** (only `Add*/Map*` calls, no logic).
- `docs/local-development.md` gets updated with the port map and the Aspire dashboard URL.

---

## 11. Observability

- **OpenTelemetry in `Hms.Platform` service defaults** for every service and the edge: ASP.NET Core, HttpClient, Npgsql and runtime instrumentation.
  YARP and HttpClient propagate W3C `traceparent` automatically, and the outbox carries `traceparent` (new column) so an
  async hop links back to the request that caused it.
- **Logs**: keep Serilog compact JSON to stdout, add `Service` + `TraceId`/`SpanId` enrichers, and keep the existing rules (no bodies,
  no PHI, ids only).
- **Metrics**: request rate/latency/error per route (OTel), plus custom `outbox_pending`, `outbox_dead`, `outbox_lag_seconds`,
  `tenant_resolution_failures_total`.
- **Health**: `/health/live` + `/health/ready` per service (DB check), edge aggregate readiness. Azure health check path = `/health/live`
  (as today).
- **Exporters**:
  - local: Aspire dashboard (free container);
  - Azure: workspace-based Application Insights via the Azure Monitor OTel exporter. Retail API (Central India): Log Analytics
    ingestion is **$0 for the first 5 GB/month, then $3.22/GB**. Use sampling at 20% for successful requests, 100% for errors, and a daily cap of
    0.15 GB to stay inside the free tier. On ACA, the environment's log destination can be "none" or Azure Monitor to avoid a mandatory Log Analytics workspace.
- **Dashboards/alerts (free)**: availability test on the edge `/health/ready` (or a GitHub Actions cron curl), and an alert on
  `outbox_dead > 0` and 5xx rate.

---

## 12. Strangler migration order (main stays green, live app keeps working)

Each phase is one PR (or a small stack) to `main`, merged only with all required checks green and Code Review approval. Each live
change has a one-step rollback.

**Prerequisites (not part of this plan's effort):** PR #2 merged; hosted DB migrations `20261008…`, `20261009…` and the Sprint 2 set
applied under the approved runbook. Don't start Phase 1's deploy while the hosted DB is mid-migration.

| Phase | Work | Live impact / rollback | Effort (dev-days) |
|---|---|---|---|
| **0. Prep inside the monolith** | Rename `Hms.Gateway` → `legacy/Hms.Monolith`. Extract `Hms.Platform` (tenancy resolution off `IdentityDbContext`, outbox, auth, health, OTel). Add published SQL surface (`patient_summary_v1`, `patient_has_open_visits_v1`, `resolve_grant_v1`) and switch the code to it. `No Reset On Close`, pool sizing and the lazy dispatcher data source move into code. Fix the Dockerfile → `service.Dockerfile`. Add the project-reference rule test and the CI `changes` + matrix skeleton. | None (same single deploy). Revert = revert PR. | **4–5** |
| **1. Edge in front of the monolith** | `Hms.Edge` (YARP, CORS, JWT pre-check, rate limit, headers, catch-all → legacy). Compose + CI E2E through the edge. Deploy the edge as a **new app** (`medicore-hms-edge`), smoke-test it, then change Vercel `VITE_API_BASE_URL` once to the edge and redeploy web. The monolith (`medicore-hms-api`) keeps running as the upstream. | Rollback = set `VITE_API_BASE_URL` back + redeploy (≈2 min). Needs Mohith's OK for the Azure + Vercel change. | **3–4** |
| **2. Extract patients** | `services/patients` host. Move code. Per-service login role (new migration). Edge route `/api/v1/patients` → patients. Monolith keeps the code reachable only by the catch-all for one release. | Rollback = edge route back to legacy (config change + restart). | **3–4** |
| **3. Extract scheduling** | Move practitioners/schedules/slots/appointments/queue. The dispatcher moves here (disable it in legacy in the same release; SKIP LOCKED makes overlap safe). `messaging.outbox` gets the `source_service`/`traceparent` migration. `HttpOutboxPublisher` stays log-only until a consumer exists. | Rollback = edge routes back; re-enable the legacy dispatcher. | **4–5** |
| **4. Extract identity** | `/me*`, `/tenants`, `/branches`, `/members`. The access-token hook (DB function) doesn't move. Highest auth risk, so last, with extra E2E (context switch, invitations). | Rollback = edge routes back. | **3–4** |
| **5. Notifications (optional, when a feature needs it)** | First real consumer (appointment reminders), `notification.inbox` idempotency, `HttpOutboxPublisher` on. Service Bus only if fan-out is needed. | New capability only. Disable = subscriber config off. | **3–5** |
| **6. Retire the monolith + harden** | Remove `legacy` from routes, compose and Azure. Optional per-service session roles (§3.2) combined with the deferred DB-hardening backlog. Tidy docs (architecture, local dev, runbooks). | Delete the app only after 1 week with zero catch-all hits (edge metric). | **3–4** |
| | **Total** | | **≈ 23–31** (≈ 20–26 without Phase 5) |

Calendar: one developer ≈ 5–6 weeks. With the current agent team working Phases 2–4 partly in parallel after Phase 1 (patients and
scheduling touch different code), ≈ 2.5–3.5 weeks. **Sprint 3 feature work slows by roughly that much** unless it runs in parallel on the
already-extracted services.

---

## 13. Hosting options and costs (Central India, retail prices)

Sources: Azure Retail Prices API (`prices.azure.com/api/retail/prices`, queried 9 Oct 2026, `armRegionName eq 'centralindia'`,
USD and INR). App Service limits: Microsoft Learn *App Service limits* + *quotas and metrics*. ACA free grant: Microsoft Learn
*Billing in Azure Container Apps*. Supabase limits: Supabase *Compute and Disk* docs. Prices exclude tax, and monthly figures use 730 h.

### 13.1 Facts that drive the choice

**App Service F1 (Free) — what we run today**
- $0.00/h (F1 Linux).
- **Up to 10 apps per Free plan**, 10 Free plans per region.
- Quotas are **per app**:
  - **CPU 60 min/day** and **3 min per 5 minutes**;
  - **outbound bandwidth 165 MB/day**.
  - When an app exceeds a quota, it is **stopped and returns HTTP 403 until the quota resets (midnight UTC = 05:30 IST)**.
- **Memory: 1,024 MB per App Service plan**, shared by all apps in it.
- 1 GB storage.
- No Always On, so apps idle out and cold-start (we see ~30–60 s).
- No VNet integration, no SLA.
- Microsoft: "Use of free plan for production workloads is not supported."

**App Service B1 Linux**
- **$0.018/h = $13.14/month; ₹1.7278/h ≈ ₹1,261/month.**
- 1 core, 1.75 GB RAM, 10 GB storage.
- **Unlimited apps per plan**. Billed per instance, not per app.
- Always On, VNet integration, 99.95% SLA.

**Azure Container Apps, Consumption plan**

| Meter | USD | INR |
|---|---|---|
| vCPU active | $0.000024/s | ₹0.0023/s |
| vCPU idle | $0.000003/s | ₹0.0003/s |
| Memory active | $0.000003/GiB-s | ₹0.0003/GiB-s |
| Memory idle | $0.000003/GiB-s | ₹0.0003/GiB-s |
| Requests | $0.40 per million | ₹38.40 per million |

- **Free each month per subscription: 180,000 vCPU-s, 360,000 GiB-s, 2 M requests.**
- Scale to zero = no compute charge. Health probes and requests from inside the environment are not billed.
- A Consumption-only environment has no management fee. That fee applies only to Dedicated profiles, private endpoints or planned maintenance.

**Other line items**
- **Container registry:**
  - GHCR with public images: free. The repo is already public.
  - Azure Container Registry Basic: $0.1666/day ≈ **$5.00/month (₹480)**. It is not needed.
- **Log Analytics:** 5 GB/month ingestion free, then $3.22/GB.

### 13.2 Option A: FREE, quickest: more apps in the existing F1 plan (`asp-medicore-hms-dev`)
- 5 apps (edge, identity, patients, scheduling, legacy during migration) ≤ 10-app limit. **$0.**
- Each app gets its own 60 CPU-min/day and 165 MB/day bandwidth. That is per app, and it's actually more total CPU than today. But **all apps share 1 GB RAM**
  (.NET apps use ~100–200 MB each, so 5 fit, but tightly) and one shared VM.
- Downsides:
  - **chained cold starts** (cold edge + cold service ≈ 60–120 s on the first request after idle);
  - all edge→service traffic counts against the edge's 165 MB/day outbound;
  - services must be public (edge-key + JWT required);
  - dispatcher sleeps with its app;
  - 403-until-05:30-IST on quota breach.
- Use for **Phases 1–2 only** (edge + legacy, then + patients). This needs no new Azure service type.

### 13.3 Option B: FREE, recommended for the microservices end-state: Azure Container Apps Consumption (Central India)
- One Container Apps environment (Consumption only, no workload profiles). Edge with external ingress; identity/patients/scheduling with
  **internal ingress**. Each runs at 0.25 vCPU / 0.5 GiB, min replicas 0, max 1–2. Images from GHCR.
- Free grant ≈ **200 replica-hours/month** at that size (180,000 vCPU-s ÷ 0.25 = 360,000 GiB-s ÷ 0.5 = 720,000 s).
- Above the grant, an active replica-hour costs **$0.027** (0.25×3600×$0.000024 + 0.5×3600×$0.000003).

| Usage scenario (4 apps: edge + 3 services) | Replica-hours/month | Est. compute cost |
|---|---|---|
| Demos/dev: each app awake ~2 h/day, 22 days | ~176 | **$0** (inside the grant) |
| Daily office-hours testing: 9 h/day, 22 days | ~792 | ≈ (792−200) × $0.027 ≈ **$16/month** |
| Kept warm 24×7 (min replicas 1, idle rate) | 2,920 | ≈ **$22/month** idle-only, before any active time |

(Estimates from retail unit prices. Actual awake time depends on traffic and the scale-down cool-down. Requests stay far below 2 M.)
- Pros: services not internet-reachable, no per-app CPU quota/403, independent scaling, container images work the same locally and in Azure.
- Cons: cold start on the first request after scale-to-zero (container start, typically seconds; **not measured for our images yet**,
  to be measured in Phase 1). It is a new platform for DevOps (environment, ingress, secrets). The dispatcher sleeps when scheduling is at zero (§4.2).
- Set a **budget alert at $1** on the subscription so any overage is visible immediately.

### 13.4 Option C: CHEAPEST PAID, recommended once the app is used daily: App Service B1 Linux, one plan, all apps
- **$13.14/month (≈ ₹1,261/month)** for edge + 3–4 services on one B1 instance (1 core, 1.75 GB). **Always On**: no cold starts, the
  dispatcher runs continuously, no daily CPU quota.
- Cheaper than keeping 4 ACA apps warm (~$22/month idle-only), and predictable.
- Services stay public behind edge-key + JWT. VNet integration is possible on B1, but private endpoints add cost and aren't needed now.
- The path from F1 is a plan SKU change (scale up `asp-medicore-hms-dev` to B1). This needs Mohith's explicit approval because it is paid.

### 13.5 Not recommended now
- Render (current alt host): to be retired per the earlier decision.
- AKS: control plane + nodes are far above our needs.
- Several Supabase projects: see §3.3.
- P0v3 Linux ($0.082/h ≈ $60/month): no need at this load.

**Database:** stays on the Supabase free (Nano) project for all options. Watch the 60-connection / 200-pooler-client and 500 MB limits (§3.4). Note:
Supabase pauses free projects after a period of inactivity, which affects every option equally.

---

## 14. Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | **Operational overhead for a tiny team**: 5 deployables, 5 configs, distributed debugging | High / Medium | One Dockerfile, one platform library, config-driven routes, OTel from Phase 0, per-service deploy workflow. |
| 2 | **Chained cold starts on free tiers** (edge + service) make the demo slower than today | High on F1, Medium on ACA / Medium | No service-to-service calls; ACA Option B; B1 when daily use starts; warm-up ping from GitHub cron during demo hours (counts against the F1 CPU quota). |
| 3 | **Shared DB means coupling remains** (schema changes in `identity` helpers affect all RLS) | Certain / Medium | Published v1 SQL surface, additive-only changes, ownership lint, SQL contract tests. Accept it consciously (§3.3). |
| 4 | **Security regressions while moving auth/tenancy** (tenant resolution, RLS session setup) | Medium / High | Code moves, not rewrites. Every service re-validates the JWT and RLS stays authoritative. The 45 cross-tenant 404 tests + E2E run through the edge on every PR. Identity extracted last. Code Review gate per phase. |
| 5 | **Services publicly reachable on App Service** | Medium / High | Edge-key header + JWT + RLS; ACA internal ingress removes it. |
| 6 | DB connection exhaustion (60 / 200 pooler) | Medium / High | Pool caps per service, `No Reset On Close`, lazy dispatcher data source, connection metrics. |
| 7 | Event duplication/loss across services | Low / Medium | Transactional outbox already exists; inbox dedupe on `event_id`; dead-letter (`status='dead'`) alert. |
| 8 | PHI in events / logs | Medium / High | ID-only payloads, no payload logging, retention on outbox/inbox, consumers treated as PHI systems (Code Review question still open: confirm with CEO). |
| 9 | Feature slowdown (Sprint 3 delayed ~3–5 weeks) | Certain / Medium | Phase 0–1 first (small), then extract services as their features are touched; or run Sprint 3 on extracted services. |
| 10 | F1 quota 403s or memory pressure with 5 apps in 1 GB | Medium / Medium | Option A only short-term; move to B (free) or C (paid). |
| 11 | Open review findings carried into the split (PR #2 MIN-1/2, Q1 Data API exposure, deferred DB hardening) | Certain / Medium | Not made worse by this plan; fold Phase 6 hardening into the deferred backlog. Answer Q1 before exposing more schemas. |
| 12 | Hosted DB migrations still pending (`20261009090000` and the Sprint 2 set) | Certain / High | Prerequisite. Apply under runbook + approval before Phase 1 deploys. |

---

## 15. Decisions needed from Mohith

1. Approve the target shape: **4 services + YARP edge on one Supabase DB (schema per service)**.
2. Hosting: **Option B (ACA free)** as the target, with Option A for Phases 1–2? Or go straight to **Option C (B1, $13.14/month)** for no cold starts?
   Nothing paid is created without an explicit yes.
3. Sequencing vs Sprint 3: migrate first (Phases 0–1 ≈ 1.5 weeks, then extractions alongside Sprint 3), or pause features until Phase 4.
4. Phase 1 live change: OK to create `medicore-hms-edge` and switch Vercel's `VITE_API_BASE_URL` to it (after smoke test)?
