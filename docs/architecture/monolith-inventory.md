# Legacy monolith inventory

Audit date: 2026-10-22. The host `backend/gateway/Hms.Gateway` is removed from the repository.
Azure App Service `medicore-hms-api` still runs the last deployed build of that host. The HTTP
surface of that host is a subset of the three services behind `Hms.Edge`. Nothing that the monolith
serves is missing from its owning service. Stopping the App Service is
`docs/runbooks/monolith-cutover.md`, and this change does not do it.

Status values:

- **in service** — the owning service already exposes it.
- **service only** — the monolith never had it.
- **edge only** — the edge answers it; services are not on the path.
- **kept off** — registered, and must stay disabled (B1).

## Endpoints

All paths are under `/api/v1` except the health routes. The edge route is the YARP cluster in
`backend/edge/Hms.Edge/appsettings.json`.

| Method and path | Owner | Edge route | Monolith | Status |
|---|---|---|---|---|
| `GET /me` | identity | `identity-me` | yes | in service |
| `POST /me/context` | identity | `identity-me` | yes | in service |
| `GET /me/invitations` | identity | `identity-me` | yes | in service |
| `POST /me/invitations/{id}/accept` | identity | `identity-me` | yes | in service |
| `POST /me/invite-links/claim` | identity | `identity-me` | yes | in service |
| `GET /tenants/current` | identity | `identity-tenants` | yes | in service |
| `PATCH /tenants/current` | identity | `identity-tenants` | yes | in service |
| `GET/POST /branches`, `PATCH/DELETE /branches/{id}`, `POST /branches/{id}/restore` | identity | `identity-branches` | yes | in service |
| `GET/POST /members`, `PATCH/DELETE /members/{id}`, `POST /members/{id}/restore` | identity | `identity-members` | yes | in service |
| `GET/POST /members/invite-links`, `DELETE /members/invite-links/{id}` | identity | `identity-members` | yes | in service |
| `POST /public/hospital-signups` | identity | `identity-public` (anonymous) | no | service only |
| `GET /public/invites/{token}` | identity | `identity-public` | no | service only |
| `POST /public/invites/{token}/sign-in-code` | identity | `identity-public` | no | service only |
| `POST /public/invites/{token}/sign-in` | identity | `identity-public` | no | service only |
| `GET /platform/hospital-requests` | identity | `identity-platform` | no | service only |
| `POST /platform/hospital-requests/{id}/approve` | identity | `identity-platform` | no | service only |
| `POST /platform/hospital-requests/{id}/reject` | identity | `identity-platform` | no | service only |
| `GET /platform/tenants`, `GET /platform/tenants/{id}`, `POST /platform/tenants` | identity | `identity-platform` | no | service only |
| `POST /platform/tenants/{id}/suspend`, `POST /platform/tenants/{id}/reactivate` | identity | `identity-platform` | no | service only |
| `POST /platform/tenants/{id}/admin-invite` | identity | `identity-platform` | no | service only |
| `GET /patients`, `POST /patients`, `GET /patients/{id}`, `PATCH /patients/{id}` | patients | `patients-patients` | yes | in service |
| `POST /patients/search`, `POST /patients/duplicates`, `GET /patients/stats` | patients | `patients-patients` | yes | in service |
| `DELETE /patients/{id}`, `POST /patients/{id}/restore`, `POST /patients/{id}/merge` | patients | `patients-patients` | yes | in service |
| `GET/POST /practitioners`, `PATCH/DELETE /practitioners/{id}`, `POST /practitioners/{id}/restore` | scheduling | `scheduling-practitioners` | yes | in service |
| `GET/POST /schedules`, `PATCH/DELETE /schedules/{id}`, `POST /schedules/{id}/restore` | scheduling | `scheduling-schedules` | yes | in service |
| `GET /slots` | scheduling | `scheduling-slots` | yes | in service |
| `GET /appointments`, `GET /appointments/{id}`, `POST /appointments` | scheduling | `scheduling-appointments` | yes | in service |
| `POST /appointments/{id}/reschedule`, `/cancel`, `/no-show`, `/check-in` | scheduling | `scheduling-appointments` | yes | in service |
| `GET /queue`, `POST /queue/walk-in`, `PATCH /queue/{id}` | scheduling | `scheduling-queue` | yes | in service |
| `GET /health/live`, `GET /health/ready` | edge (and each service for itself) | edge answers the public pair | yes, for its own process | edge only on the public URL |
| `GET /api/v1/warmup` | edge | edge probes the three services | no | edge only |

There is no catch-all route to the App Service. A prefix that is not in the table is not routed.

## Workers and jobs

| Worker or job | Where it runs | Monolith | Status |
|---|---|---|---|
| `OutboxDispatcher` (`AddHmsOutboxDispatcher`) | scheduling `Program.cs` only (the repo host is gone) | the App Service process still has the last deployed registration | **kept off**. `Outbox:Dispatcher:Enabled` is false on scheduling and must stay false on `medicore-hms-api` (B1). `hms_api` is not a member of `hms_dispatcher`. |
| `EmailOutboxDispatcher` | identity only (`Email:Dispatcher:Enabled`) | not registered | service only. Off until SMTP is configured; the ACA rollout sets it on `ca-hms-identity` only. |
| pg_cron `hms-close-stale-queues` (`*/15 * * * *`, `select appointment.close_stale_queues()`) | database, migration `20261020150000_scheduling_enable_pg_cron.sql` | not an app worker | in service (scheduling schema). No app change. |

## Config the monolith carries

Recorded from the removed `backend/gateway/Hms.Gateway/appsettings.json`:

| Key | Monolith value | Service equivalent |
|---|---|---|
| `ConnectionStrings:HmsDatabase` | user `hms_api_login` | `hms_identity_login` / `hms_patients_login` / `hms_scheduling_login` |
| `Database:SessionRole` | absent, so the session role stays `authenticated` | `hms_svc_identity` / `hms_svc_patients` / `hms_svc_scheduling` |
| `Database:MaxPoolSize` | absent | `5` on each service |
| `Auth:Supabase` | same shape, empty local secrets | same |
| `Cors:AllowedOrigins` | localhost 5173 and 4173 | empty (the edge owns CORS) |
| `RateLimiting:PermitPerMinute` | 120 | 120 on services; 300 on the edge |
| `Edge:Key` | absent | present (empty in source, set in Azure) |
| `Email` / `Smtp` | absent | identity only |
| `Outbox` | absent (dispatcher registered in code, enabled only when the flag is true) | scheduling only, flag false |

## Clients of the monolith

| Client | What it points at | Action |
|---|---|---|
| Vercel project `medicore-hms`, `VITE_API_BASE_URL` production and preview | `https://medicore-hms-api.azurewebsites.net` (set outside the repo) | **Do not change in this change.** Cutover step in `docs/runbooks/monolith-cutover.md`. |
| `apps/web` local and Docker | empty `VITE_API_BASE_URL` falls back to same-origin; Docker build arg is `http://localhost:8080` (the edge) | already on the edge |
| `scripts/dev/run-microservices.sh` | edge on :8080 | already the default dev path |
| Playwright default | that dev script | already the edge. Jenkins publishes the four hosts and sets `HMS_MS_PUBLISH`. |
| `scripts/smoke/deploy-smoke-sprint2.sh` | refuses an empty `API_URL` and refuses the App Service hostname | operator sets the public edge URL |
| `.github/workflows/ci.yml` | integration runs through the edge only; image matrix is edge, identity, patients, scheduling | monolith job and `infra/docker/api.Dockerfile` removed |
| `docker-compose.yml` | edge on :8080, no monolith profile | removed with the host |
| `infra/render/render.yaml` | retired comment, no image | not deployed |
| `backend/tests` | `Hms.TestHost` for in-process unit tests; `HmsApiFactory` is `edge` or `edge-url` | gateway project removed. Test host is not deployed. |
| `docs/runbooks/deploy-azure.md`, `deploy-sprint-2-hosted.md` | historical zip-deploy of `Hms.Gateway` | left as history. The live path is `docs/deploy.md` (Container Apps) plus the cutover runbook. |

## Cross-schema access

A service role must not `SELECT` another service's tables. The one C# read that did,
`BranchScope` selecting `identity.branches`, now calls `identity.branch_exists_v1`. Soft-deleted
branches are unknown (404) for every caller, including the legacy host, once
`20261022140000` is applied. Previously a tenant admin could see the row and received 403.

Approved calls (the file contains `cross-schema: approved`):

| Caller | Function | Why |
|---|---|---|
| every service (`NpgsqlMembershipStore`) | `identity.my_tenant_grant_v1`, `identity.my_active_context` | membership for the request |
| every service (RLS policies and `auth.uid()` in policies) | `identity.current_tenant_ids`, `has_tenant_role`, `has_tenant_permission`, `can_access_branch`, `auth.uid()` | row security |
| patients | `identity.tenant_default_country_code_v1`, `identity.branch_exists_v1`, `appointment.patient_last_booked_v1` | country default, branch check, recent patients |
| scheduling | `patient.patient_summary_v1`, `identity.branch_exists_v1` | names on the board, branch check |
| identity, as `hms_mailer` | `messaging.claim_email_outbox`, `complete_outbox`, `fail_outbox`, `email_sends_today`, `email_already_sent`, `record_email_sent` | email worker. Not the service role. |
| scheduling, as `hms_dispatcher` | `messaging.claim_outbox`, `complete_outbox`, `fail_outbox` | outbox worker. Stays disabled. |

`appointment.reassign_patient_for_merge` stays owner-only. The patients merge function calls it as
the table owner. It is not granted to `hms_svc_patients`.

Foreign keys that cross schemas stay. The table owner enforces them; the service role has no
`SELECT` on the other table. They are the seam a physical database split would replace
(`docs/adr/0002-database-per-service.md`):

- `patient.patients` and `patient.patient_phones` and `patient.mrn_counters` → `identity.tenants` / `identity.branches`
- `appointment.practitioners`, `schedules`, `appointments`, `queue_entries` → `identity.tenants` / `identity.branches` and `patient.patients`
- `identity.pending_emails`, `identity.email_sign_in_codes`, invite tables → `identity` only (same owner)
- `auth.users` columns `active_tenant_id` / `active_branch_id` → `identity` (GoTrue, not a service)

Historical migrations that mention another schema are not rewritten. New migrations and current
service code are what `.github/scripts/check-schema-ownership.sh` checks.
