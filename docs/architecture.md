# Architecture overview

_Owner (simulated): CTO / Solution Architect. Status: Sprint 0._

## Shape: a modular monolith with service boundaries

The brief (section 6) lists twelve logical services. For free-tier hosting we run **one** ASP.NET Core process (the gateway) that hosts independent modules. Each module owns:

| Concern | Rule |
|---|---|
| Code | Its own class library: `backend/modules/<Service>/Hms.Modules.<Service>` |
| Data | Its own PostgreSQL schema (`identity`, `patient`, ...) and its own `DbContext` |
| API | Its own route group under `/api/v1/...` |
| Dependencies | Only `Hms.SharedKernel`. Modules never reference each other. |
| Events (planned) | A transactional outbox table per schema, introduced with the first cross-module workflow |

These rules mean any module can later be pulled out into its own deployable service: give it its own host, keep its schema, and swap in-process calls for HTTP or events.

```mermaid
flowchart LR
  subgraph Browser
    SPA[React SPA<br/>Vercel]
  end
  subgraph Render["Render (Docker)"]
    GW[Hms.Gateway<br/>auth · tenant resolution · rate limit · health · OpenAPI]
    ID[Identity & Tenant module]
    PT[Patients module]
    FUT[Appointment · Clinical · Billing · ...<br/>later sprints]
    GW --> ID
    GW --> PT
    GW -.-> FUT
  end
  subgraph Supabase
    AUTH[Supabase Auth<br/>JWT issuer]
    PG[(PostgreSQL<br/>schemas: identity · patient · audit<br/>RLS on every table)]
  end
  SPA -- "Bearer JWT (no tenant header)" --> GW
  SPA -- sign-in --> AUTH
  ID --> PG
  PT --> PG
  GW -- "JWKS validation (Sprint 1)" --> AUTH
```

## Service status

| Service (brief §6) | Schema | Sprint 0 status |
|---|---|---|
| Identity & Tenant | `identity` | Tables, RLS, helper functions, EF mapping, tenant resolution middleware, `/api/v1/me`, `/api/v1/tenants/current` |
| Patient | `patient` | Patient registry table, RLS, list/get/create endpoints |
| Audit | `audit` | Append-only `audit_log` populated by triggers. No API yet. |
| Appointment, Clinical, Billing, Pharmacy, Inventory, Laboratory, Admission, Notification, Reporting | — | Not started (roadmap sprints 2+) |

## Request pipeline (gateway)

`ForwardedHeaders → ExceptionHandler → SecurityHeaders → Serilog request logging → (Swagger in Development) → CORS → Authentication (JWT) → TenantResolution → RateLimiter → Authorization → endpoints`

- **Authentication:** JWT bearer, configured for Supabase Auth (`Auth:Supabase:ProjectUrl`). If that is unset, every token is rejected (fail closed). Full JWKS validation is a Sprint 1 TODO; see `AuthenticationSetup.cs`.
- **Tenant resolution:** see [multi-tenancy-and-security.md](multi-tenancy-and-security.md).
- **Health:** `/health/live` checks the process only. `/health/ready` also checks the database (`DbContextCheck`).
- **Logging:** compact JSON to stdout. `TenantId` and `UserId` are attached through a logging scope. Request bodies are never logged.
- **OpenAPI:** `/openapi/v1.json` and Swagger UI at `/swagger`. Both are on in Development, and off by default elsewhere (`OpenApi:Enabled`).

## Data ownership and migrations

- `supabase/migrations/*.sql` is the **single source of truth** for the schema. EF Core maps the existing tables (snake_case naming convention). EF migrations are not used.
- `Hms.DatabaseTests` checks that the EF model matches the migrated schema.

## Frontend

- `apps/web` is a Vite SPA. Routes: `/login`, `/` (dashboard), `/patients`, and a 404 page inside the shell.
- The typed API client (`src/lib/api/client.ts`) attaches the bearer token and **never sends a tenant header**.
- Sprint 0 uses a placeholder demo session with synthetic memberships. Sprint 1 replaces it with Supabase Auth and `GET /api/v1/me`.

## Deployment targets (not deployed)

| Component | Target | Config |
|---|---|---|
| Web | Vercel | `infra/vercel/vercel.json` |
| API | Render (Docker, free plan) | `infra/render/render.yaml`, `infra/docker/api.Dockerfile` |
| DB | Supabase Free | `supabase/migrations` |
| Local | Docker Compose | `docker-compose.yml` |
