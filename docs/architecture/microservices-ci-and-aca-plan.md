> **Superseded (25 Oct 2026):** historical record. Render and the monolith are retired; current system is microservices on Azure Container Apps. See [docs/HANDOVER.md](/docs/HANDOVER.md).

# MediCore HMS microservices: CI per service + Azure Container Apps plan (PLAN ONLY)

Status: **PLAN, nothing executed.** Written 9 Oct 2026, ~18:40 IST, from `main @ 1306b8a` (Sprint 2 merged).

**Update October 2026:** `.github/workflows/ci.yml` now has a `changes` job, per-job pass markers, reporter jobs for the four required check names, and a `ci-ok` aggregate. Nightly `schedule` and `workflow_dispatch` run everything and ignore the pass cache. The reusable per-service workflows in this plan are still not what CI runs.
**Update 19 Oct 2026 (IST), rebased on main @ 495f987 (PRs #4, #5, #6 merged):** the code gaps listed at prep time are
closed on main: edge-key / pool-size / routing code is committed, `backend/edge/Dockerfile` plus one Dockerfile per service
exist, and CI builds and health-smokes every image (non-required). Still open before Deploy day: (1) no workflow *publishes*
images to GHCR yet (the draft deploy workflow builds and pushes them itself once enabled); (2) the edge still has no catch-all to
the monolith, so the cutover moves every route at once; (3) the deploy script gives all three services one `hms-db` secret
(the shared `hms_api_login`) with the outbox dispatcher disabled. Per-service logins (`hms_<svc>_login`, migration
20261013090100) need a hosted write and are a follow-up approval. Note B1: on the upgraded schema `hms_api` no longer holds
`hms_dispatcher`, so the legacy API's outbox dispatcher cannot claim rows; it must stay disabled on the F1 app.
Hosted Supabase does not yet have the Sprint 2, audit-tz or microservices migrations.

Companion to `/workspace/MICROSERVICES-PLAN.md` (approved shape, §0.1: `identity`, `patients`, `scheduling` + YARP `edge`,
one Supabase Postgres with a schema per service, Azure Container Apps Consumption in Central India).

> **Nothing in this document has been run.** No Azure resource, provider registration, budget, Entra app, role assignment,
> GHCR package, branch-protection change, Vercel env change or hosted-Supabase write has been made. Every command that
> changes anything is in a block marked **DO NOT RUN until approved**, and each maps to an item in §7.
> Secrets never appear here. The DB connection string is only ever read inside the shell with
> `$(tr -d '\n' < /home/box/.secrets/medicore-hms-connstr)`; never `set -x`, always `-o none`, never echo it.

Read-only facts gathered for this plan (box, 9 Oct 2026 ~18:30 IST):

| Check | Result |
|---|---|
| Subscription | `Azure subscription 1` (`6f4c512a-8528-461a-962b-f4f8525223a3`), state Enabled |
| Offer / quota id | **`PayAsYouGo_2014-09-01`, `spendingLimit: Off`** (ARM `GET /subscriptions/{id}`) |
| `Microsoft.App` provider | **NotRegistered** (must be registered before any Container Apps create; free, but a subscription change) |
| `Microsoft.OperationalInsights` provider | NotRegistered (good: we don't want a Log Analytics workspace) |
| Container Apps regions | `managedEnvironments` lists **Central India** and South India |
| ACA usages, centralindia | `ManagedEnvironmentCount 0/0` (limit reads 0 while the provider is unregistered; re-check after registration) |
| Budgets on the subscription | none (`Microsoft.Consumption/budgets` → `[]`) |
| Existing medicore resources | `rg-medicore-hms-dev`: `asp-medicore-hms-dev` (F1) + `medicore-hms-api` only. Other projects' resources exist in the same subscription (other RGs) and are not touched. |
| az CLI | 2.91.0; `az containerapp env create` defaults: `--logs-destination log-analytics` (would create a workspace), `--enable-workload-profiles true` |
| Repo | public, owner `kakani-dev` is a **User** account; no rulesets on `main`; classic protection read returns 404 for the box's gh account (`kakani17481a0566`, not admin), so Mohith must read it himself (§1.6) |
| CI on `1306b8a` | all 6 checks green (4 required + 2 non-required), longest = Playwright E2E ~2 min |

---

## 1. CI per service

### 1.1 Constraint that shapes the design

GitHub docs ("Troubleshooting required status checks", *Handling skipped but required checks*):

| Cause | Result |
|---|---|
| Whole **workflow** skipped by `on.*.paths` / branch filter | its checks stay **Pending** and **block the merge** |
| **Job** skipped by an `if:` | reports **Success** (`success`, `skipped`, `neutral` all satisfy a required check) |
| Job skipped because a `needs:` job **failed** | skipped → can look green → use `if: always()` + explicit result checks |

So path filtering must happen **inside** an always-running workflow (job-level `if:`), never with workflow-level
`paths:` on anything that is a required check. "One workflow per service" is therefore implemented as **one reusable
workflow per kind of unit + one thin caller per service**, orchestrated by an always-running `ci.yml` that owns the
required check names.

### 1.2 Files

```
.github/workflows/
  ci.yml                    # orchestrator; on: pull_request, push(main), merge_group, workflow_dispatch. NO paths filter.
  _dotnet-service.yml       # reusable (on: workflow_call): build, unit, integration(DB), contract tests for ONE service
  _web.yml                  # reusable: lint, unit, build of apps/web (today's "Frontend" job body)
  _sql.yml                  # reusable: migrations + seed + SQL/RLS tests (today's run-sql-tests.sh), with a test-dir selector
  _image.yml                # reusable: docker build (+cache), SBOM, Trivy scan, (main only) push to GHCR + attest
  _e2e.yml                  # reusable: compose stack (postgres + mock-auth + edge + services [+ legacy]) + Playwright
  _aca-deploy.yml           # reusable: deploy ONE image sha to ONE container app (environment-gated)
  svc-identity.yml          # thin callers, on: workflow_dispatch only (manual rebuild / redeploy / rollback to a sha)
  svc-patients.yml
  svc-scheduling.yml
  svc-edge.yml
  web.yml                   # manual web-only rerun (Vercel still builds/deploys web itself)
  cleanup.yml               # unchanged
```

The per-service caller files are path-free and dispatch-only, so they can never leave a required check pending. The
automatic per-service behaviour (run only what changed) comes from `ci.yml`'s `changes` job.

### 1.3 `ci.yml` orchestrator (shape)

```yaml
on:
  pull_request:
  merge_group:                 # only matters if a merge queue is enabled later
  push: { branches: [main] }
  workflow_dispatch:
permissions: { contents: read }
concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: ${{ github.ref != 'refs/heads/main' }} }

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs: { web: ..., edge: ..., identity: ..., patients: ..., scheduling: ..., legacy: ..., db: ..., all: ... }
    steps:
      - uses: actions/checkout@v7
      - uses: dorny/paths-filter@<pinned-sha>    # v3
        id: f
        with:
          filters: |
            all:        # anything shared => run EVERYTHING
              - 'backend/platform/**'
              - 'backend/shared/**'
              - 'backend/contracts/**'
              - 'contracts/**'
              - 'backend/Directory.*.props'
              - 'backend/global.json'
              - 'backend/Hms.slnx'
              - '.github/workflows/**'
              - 'infra/docker/**'
              - 'docker-compose*.yml'
              - 'package*.json'
              - 'tests/**'
            db:         ['supabase/**', 'backend/tests/Hms.DatabaseTests/**']
            web:        ['apps/web/**']
            edge:       ['backend/edge/**']
            identity:   ['backend/services/identity/**', 'backend/modules/Identity/**']
            patients:   ['backend/services/patients/**', 'backend/modules/Patients/**']
            scheduling: ['backend/services/scheduling/**', 'backend/modules/Appointments/**']
            legacy:     ['backend/gateway/**', 'backend/legacy/**', 'backend/modules/**']
      # db => all services' integration tests + E2E (shared DB), see §2.4

  identity:   { needs: changes, if: needs.changes.outputs.identity == 'true' || needs.changes.outputs.all == 'true' || needs.changes.outputs.db == 'true',
                uses: ./.github/workflows/_dotnet-service.yml, with: { service: identity, project: backend/services/identity/Hms.Identity.Api, tests: backend/services/identity/Hms.Identity.Tests, dockerfile: backend/services/identity/Dockerfile } }
  patients:   { ... same, service: patients ... }
  scheduling: { ... same, service: scheduling ... }
  edge:       { ... same, service: edge (no DB tests; YARP route-table tests) ... }
  legacy:     { ... same, service: legacy, dockerfile: infra/docker/api.Dockerfile ... }   # until Phase 6
  web:        { needs: changes, if: web||all, uses: ./.github/workflows/_web.yml }
  sql:        { needs: changes, if: db||all||any service, uses: ./.github/workflows/_sql.yml }
  images:     { needs: [changes, <service jobs>], strategy.matrix over changed services, uses: ./.github/workflows/_image.yml,
                with: { push: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }} } }
  e2e:        { needs: changes, if: web||edge||any service||db||all, uses: ./.github/workflows/_e2e.yml }

  # ---- compatibility names (exactly today's required checks; see 1.6) ----
  frontend-compat: { name: "Frontend (lint, unit tests, build)", if: always(), needs: [changes, web], ... }
  backend-compat:  { name: "Backend (build + unit tests)", if: always(), needs: [changes, identity, patients, scheduling, edge, legacy], ... }
  database-compat: { name: "SQL/RLS tests + API integration tests (real Postgres)", if: always(), needs: [changes, sql, identity, patients, scheduling, legacy], ... }
  e2e-compat:      { name: "Playwright E2E (web + API + mock auth + Postgres)", if: always(), needs: [changes, e2e], ... }

  # ---- the single future required check ----
  ci-gate:
    name: CI gate
    if: always()
    needs: [changes, web, sql, identity, patients, scheduling, edge, legacy, images, e2e]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any needed job failed or was cancelled (skipped is fine)
        run: |
          echo '${{ toJSON(needs) }}' | jq -e 'to_entries | all(.value.result == "success" or .value.result == "skipped")'
      - name: changes must itself have succeeded (otherwise everything was skipped = false green)
        run: test "${{ needs.changes.result }}" = success
```

Each `*-compat` job uses the same two-step check as `ci-gate` over its own `needs`, so it is green when its part was
skipped by the filter, red when any part failed, and **never pending**. The explicit `changes == success` check closes
the "dependency failed → everything skipped → green" hole.

Non-required jobs stay as today (`db-supabase-prototype`, `web-e2e-mocked`) and gain the same `if:` filters.

### 1.4 Reusable `_dotnet-service.yml` (per service)

Inputs: `service`, `project`, `tests`, `dockerfile`, `needs-db` (bool).

1. `actions/setup-dotnet@v6` (10.0.x) + `actions/cache` on `~/.nuget/packages`, key
   `nuget-${{ runner.os }}-${{ hashFiles('backend/Directory.Packages.props','backend/**/*.csproj','backend/global.json') }}`
   (no `packages.lock.json` in the repo today, so `setup-dotnet`'s built-in cache can't be used; optional follow-up:
   enable `RestorePackagesWithLockFile` and switch to it).
2. `dotnet restore/build -c Release <project>` and its test project only.
3. **Unit**: `dotnet test <tests> --filter "Category!=Database"`.
4. **Integration** (`needs-db`): `postgres:17` service container + `bash supabase/scripts/run-sql-tests.sh` with
   `SKIP_SQL_TESTS=1` (apply the full migration chain + seed only), then `dotnet test <tests> --filter "Category=Database"`
   with the per-service `WebApplicationFactory`. Throwaway CI credentials only (as today: `hms_api_local_only`; per-service
   local logins `hms_<svc>_login` once §2.2 lands). **Never** the hosted password, **never** `postgres/postgres` outside CI.
5. **Contract** (fast, no DB unless noted):
   - OpenAPI snapshot: build, dump `/openapi/v1.json` via `WebApplicationFactory`, diff against
     `contracts/http/<service>.openapi.json`; fail on breaking diff unless the PR has label `api-breaking`
     (`oasdiff breaking` - free, Apache-2.0).
   - Architecture rule: the service project may reference only `Hms.Platform` / `Hms.Contracts.*` and its own module
     (Phase 0 already adds `ArchitectureTests.cs`).
   - Published SQL surface (`docs/contracts/db.md`, Phase 0): asserts the `_v1` views/functions exist with the expected
     signatures (runs in the DB step).
   - Event schemas (scheduling): envelope + `AppointmentBookedV1`… validate against `contracts/events/*.json`.
   - Edge only: YARP route-table test (every prefix in MICROSERVICES-PLAN §5 maps to the right cluster, `/internal/**` → 404,
     `X-Hms-*` request headers stripped, `Authorization` forwarded unchanged).
6. Upload TRX results (`retention-days: 7`, as today).

Transitional note: today there is one `Hms.UnitTests` and one `Hms.IntegrationTests` project. Until Phases 2–4 move tests
into `backend/services/<svc>/Hms.<Svc>.Tests`, the reusable workflow filters the shared projects with a trait:
`--filter "Service=<Service>&Category!=Database"` (add `[Trait("Service", "...")]`; untagged tests run in the `legacy` leg).

### 1.5 Reusable `_image.yml` (build, SBOM, scan, push)

Runs on every PR (build + scan, **no push**) and on push to `main` (build + scan + push + attest), for changed services only.

```yaml
permissions: { contents: read, packages: write, id-token: write, attestations: write, security-events: write }  # job level; push/attest only on main
steps:
  - uses: docker/setup-buildx-action@<sha>
  - uses: docker/login-action@<sha>            # main only; registry ghcr.io, username ${{ github.actor }}, password ${{ secrets.GITHUB_TOKEN }}
  - uses: docker/metadata-action@<sha>
    with:
      images: ghcr.io/kakani-dev/hms-${{ inputs.service }}
      tags: |
        type=sha,format=long,prefix=sha-       # immutable: sha-<40 hex>  (the ONLY tag deploys use)
        type=raw,value=main,enable={{is_default_branch}}   # moving convenience tag, never deployed
      labels: |
        org.opencontainers.image.source=https://github.com/kakani-dev/hospital-management-system   # links package to repo
  - uses: docker/build-push-action@<sha>
    with:
      file: ${{ inputs.dockerfile }}
      context: .
      push: ${{ inputs.push }}
      load: ${{ !inputs.push }}
      sbom: true                                 # BuildKit SPDX attestation (free)
      provenance: mode=max
      cache-from: type=gha,scope=img-${{ inputs.service }}
      cache-to:   type=gha,scope=img-${{ inputs.service }},mode=max
  - name: Boot + /health/live smoke (no DB)      # Phase 0 already does this in its non-required "images" job
  - uses: anchore/sbom-action@<sha>              # Syft, SPDX JSON artifact (free)
  - uses: aquasecurity/trivy-action@<sha>        # image scan; fail on CRITICAL with a fix available, report HIGH
    with: { severity: CRITICAL,HIGH, ignore-unfixed: true, format: sarif, output: trivy.sarif }
  - uses: github/codeql-action/upload-sarif@<sha>   # code scanning is free for public repos
  - uses: actions/attest-build-provenance@<sha>  # main only, pushed digest (free for public repos)
```

Also free and recommended: GitHub secret scanning + push protection (free on public repos; a repo-settings change,
approval item A9), Dependabot for `nuget`, `npm`, `github-actions`, `docker`. `dotnet list package --vulnerable` and
`npm audit --omit=dev` as non-blocking report steps. Not `gitleaks-action` (needs a license key for orgs; not needed here).

Pin all third-party actions by full commit SHA (matches the existing supply-chain posture).

Image hygiene (cold-start relevant): switch runtime stage to `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled`
(smaller, non-root by default) once the health smoke passes on it; keep `UseAppHost=false`. Measure cold start before/after.

### 1.6 Required checks: migration without blocking PRs

Today's required names (from the task; the box's gh account can't read protection, so Mohith confirms with step 0):

1. `Frontend (lint, unit tests, build)`
2. `Backend (build + unit tests)`
3. `SQL/RLS tests + API integration tests (real Postgres)`
4. `Playwright E2E (web + API + mock auth + Postgres)`

Stages:

| Stage | Repo change (PR) | Protection change (Mohith) | Why it doesn't block |
|---|---|---|---|
| S0 | none | **Step 0: read current protection** (command below) | – |
| S1 | PR "ci: orchestrator": new `ci.yml` with the four `*-compat` jobs emitting the **exact four names** + new `CI gate` | none | Same names still reported on every PR/commit, always (never pending). Open PRs keep working; they pick up the new jobs on their next push/merge of `main`. |
| S2 | – (wait until `CI gate` has been green on `main` for ≥3 runs and on ≥2 PRs; GitHub only offers a check for protection after it ran in the last 7 days) | **Add `CI gate`** to required (now 5) | Every PR branched after S1 reports it. PRs older than S1 must merge `main` (or rebase) once, which they must anyway with "require up-to-date". |
| S3 | – (1 week later) | **Replace the list with only `CI gate`** | Old names are still reported, so nothing pending; `CI gate` already covers them. |
| S4 | PR "ci: drop compat jobs" | none | Merge only **after** S3 is live; otherwise every PR waits forever for the removed names. |

Commands for Mohith (**DO NOT RUN until approved; must be run by a repo admin, i.e. Mohith's own gh login**):

```bash
R=kakani-dev/hospital-management-system
# Step 0 (read-only): current required checks + strict flag
gh api repos/$R/branches/main/protection/required_status_checks
# S2: add "CI gate" (keeps the existing four)
gh api -X POST repos/$R/branches/main/protection/required_status_checks/contexts \
  --input - <<'JSON'
{"contexts":["CI gate"]}
JSON
# S3: required = only "CI gate" from GitHub Actions (app_id 15368). Keep "strict" at the value read in step 0.
gh api -X PATCH repos/$R/branches/main/protection/required_status_checks \
  --input - <<'JSON'
{"strict": true, "checks": [{"context": "CI gate", "app_id": 15368}]}
JSON
# Rollback of S3 (restore the four):
gh api -X PATCH repos/$R/branches/main/protection/required_status_checks --input - <<'JSON'
{"strict": true, "checks": [
 {"context":"Frontend (lint, unit tests, build)","app_id":15368},
 {"context":"Backend (build + unit tests)","app_id":15368},
 {"context":"SQL/RLS tests + API integration tests (real Postgres)","app_id":15368},
 {"context":"Playwright E2E (web + API + mock auth + Postgres)","app_id":15368}]}
JSON
```
(If step 0 shows `"strict": false`, use `false` in S3 and its rollback.)

### 1.7 Deploy pipeline (main only, environment-gated)

After `CI gate` is green on a `push` to `main`, `ci.yml` runs `deploy-<svc>` jobs (only for services whose image was just
pushed) calling `_aca-deploy.yml` with `environment: aca-dev` (**required reviewer: Mohith** for the first weeks;
GitHub environments with reviewers are free on public repos). Deploy = `az containerapp update -n ca-hms-<svc> -g
rg-medicore-hms-dev --image ghcr.io/kakani-dev/hms-<svc>:sha-<sha> --revision-suffix <shortsha> -o none`, then a
`/health/ready` poll through the edge. `concurrency: deploy-<svc>`, `cancel-in-progress: false`.
Rollback / redeploy of any earlier sha: `svc-<name>.yml` via `workflow_dispatch` with input `sha`.
**No hosted DB migration ever runs from CI** (stays runbook + Mohith's approval, as today).
Order on a release that includes a migration: DB (runbook) → services → edge → web, and services must tolerate both
schema N and N+1 (expand/contract).

Auth for the deploy job: GitHub OIDC → Entra (§3.10, approval A6). Until approved, deploy runs from the box with the
signed-in az CLI (same commands), and the CI deploy job is left disabled (`if: vars.ACA_DEPLOY_ENABLED == 'true'`).

### 1.8 Expected CI time / cost

Public repo → GitHub-hosted Linux minutes are free. A one-service PR runs: changes (~10 s) + one service (~1–2 min) +
SQL (~1.5 min, only if DB/service touched) + image build (~1–2 min cached) + E2E (~3–4 min; today 2 min single API, +1–2 min
for the compose stack). GHA cache limit is 10 GB/repo; `cleanup.yml` already prunes caches unused for 7 days.

---

## 2. Database: one Supabase, schema per service

### 2.1 Ownership

| Schema | Owner | Notes |
|---|---|---|
| `identity` | identity service | tenants, branches, memberships, profiles, invites, access-token hook, RLS helpers (`has_tenant_role`, `can_access_branch`, `current_tenant_ids`, `my_memberships`, `my_active_context`, `resolve_grant_v1`) = published authorisation API, additive-only |
| `patient` | patients service | registry, duplicates, soft delete/restore, `patient_summary_v1` (published) |
| `appointment` | scheduling service | practitioners, schedules, slots, appointments, queue; `patient_has_active_visits_v1` (published) |
| `messaging` | scheduling service (producer + dispatcher) | `outbox`; becomes shared-producer when other services emit (MICROSERVICES-PLAN §4.2), owner stays scheduling until a `notifications` service exists |
| `audit` | **platform** (DB team) | triggers on every business table; changes need the full CI matrix (`all` filter) |
| `tests` (CI only) | platform | `supabase/tests/00_test_helpers.sql` |

Data API: `appointment` and `messaging` stay **out** of Supabase's exposed schemas (CTO instruction); this plan changes
nothing in Data API settings.

### 2.2 Migrations: ownership and ordering in CI

- **One chain** stays in `supabase/migrations` (cross-schema FKs and RLS helpers need a global order).
- New files: `<yyyymmddHHMMSS>_<owner>_<what>.sql`, owner ∈ `platform|identity|patients|scheduling`. The 15 existing
  files are grandfathered (mapping kept in `docs/contracts/db.md`).
- CI lint (`_sql.yml`, part of `CI gate`):
  1. timestamp of every **new** file > max timestamp on `main` (prevents out-of-order merges; with "require up-to-date"
     the second racing PR must rebase and rename);
  2. DDL in a file only touches its owner's schema (`create|alter|drop|grant|revoke|comment on … <schema>.`), unless the
     file starts with `-- cross-schema: approved` **and** CODEOWNERS for the other schema approved;
  3. no edits to already-merged migration files (diff against `main`; fixes go in a new file).
- CODEOWNERS: `supabase/migrations/*_identity_*` → identity owner, etc.; `*_platform_*` and `supabase/scripts/**` → DB lead.
- Any change under `supabase/**` sets the `db` filter ⇒ SQL tests + **every** service's integration tests + E2E (shared DB).
- Hosted apply: unchanged process (runbook + backup + guarded transaction + Mohith's approval). Never from CI.
- Per-service login roles (`hms_identity_login`, `hms_patients_login`, `hms_scheduling_login`, NOINHERIT, own nothing,
  granted `hms_api`; scheduling also `hms_dispatcher`) arrive as a `platform` migration in Phase 2. In CI they get
  throwaway passwords; on hosted, passwords are generated on the box into `/home/box/.secrets/` (never git/chat) and
  the role creation is a hosted write (approval A11). Until then **all** services use the existing
  `medicore-hms-connstr` (`hms_api_login`).

### 2.3 Connection budget

Supabase free (Nano): 60 DB connections / 200 pooler clients. Each service: `Maximum Pool Size=10;Minimum Pool Size=0;
No Reset On Close=true;Max Auto Prepare=0` (Phase 0 moves these into code via `NpgsqlConnectionStringBuilder`, so the
secret only carries host/user/password). 3 services × max 1 replica × 10 = 30 pooler clients worst case (+10 for the F1
monolith while it runs).

### 2.4 SQL/RLS test split

`run-sql-tests.sh` keeps applying the **whole** chain + seed (the DB is shared); only the test selection splits:

```
supabase/tests/
  platform/    00_test_helpers, 01_schema_guardrails, 04_constraints, 05_audit, 14_sprint2_guardrails (split per schema later)
  identity/    02_tenant_isolation, 03_roles_and_branches, 06_auth_hook_and_context, 07_api_role,
               08_membership_invite_consent, 09_membership_invite_per_branch
  patients/    10_patient_soft_delete_and_duplicates
  scheduling/  11_appointment_schema, 12_opd_queue, 13_outbox
  mixed/       15_pr2_review_fixes   (touches patient + appointment; split when next edited)
  contracts/   16_ms_phase0_published_contracts (Phase 0 branch)
```

- `run-sql-tests.sh` gains `SQL_TEST_DIRS` (default: all). PR touching only `services/patients` → `platform patients contracts`.
  Any `supabase/**` change → all dirs. Total runtime is ~1.5 min today, so the split is about ownership/blast radius,
  not speed.
- Cross-tenant 404 API tests (45) and the 172 integration tests move to `Hms.SystemTests` run **through the edge**
  (in-process YARP → in-process `TestServer`s), in the `legacy`/`edge` legs and always on `db`/`all` changes.
- The required DB check name stays `SQL/RLS tests + API integration tests (real Postgres)` (compat job) until S3.

---

## 3. Azure Container Apps setup

### 3.1 Topology

> **Updated by §8.2:** the edge code on the in-progress `ms/services` worktree routes all ten `/api/v1` prefixes to
> the three services and answers anything else with 404 (no legacy catch-all), and services are addressed as
> `http://ca-hms-<svc>/` (ACA app-name DNS, internal ingress with `allowInsecure`). `infra/aca/deploy-aca.sh` follows the code.

```
Browser (Vercel SPA: medicore-hms-three.vercel.app)
   │ HTTPS, Authorization: Bearer <Supabase JWT>
   ▼
ca-hms-edge      external ingress :8080  (YARP: CORS, JWT pre-check, rate limit, headers, routing; no DB)
   │  https://<app>.internal.<env-default-domain>   (environment-internal only)
   ├──► ca-hms-identity    internal ingress :8080 ─┐
   ├──► ca-hms-patients    internal ingress :8080 ─┼──► Supabase Postgres (Supavisor :6543, ap-south-1)
   ├──► ca-hms-scheduling  internal ingress :8080 ─┘     (+ outbox dispatcher in scheduling)
   └──► catch-all /api/v1/** → legacy monolith = existing F1 app https://medicore-hms-api.azurewebsites.net
                                 (until Phase 6; avoids a 5th ACA app, see decision D2)
```

| Item | Value |
|---|---|
| Resource group | `rg-medicore-hms-dev` (existing, centralindia; one budget scope for F1 + ACA) |
| Environment | `cae-medicore-hms-dev`, **Consumption-only** (`--enable-workload-profiles false`), `--logs-destination none`, no VNet, no private endpoint, not zone-redundant |
| Apps | `ca-hms-edge`, `ca-hms-identity`, `ca-hms-patients`, `ca-hms-scheduling` |
| Images | `ghcr.io/kakani-dev/hms-<svc>:sha-<40hex>` (public GHCR, anonymous pull) |
| Size | **0.25 vCPU / 0.5 Gi** each (smallest valid pair). .NET 10 API + Npgsql pool fits in 0.5 Gi; raise to 0.5/1.0 only if OOM is observed (doubles grant burn) |
| Scale | `min 0`, `max 1`, HTTP rule `concurrentRequests=20`. Max 1 is a cost guardrail, not a perf choice |
| Revision mode | **single**; `--revision-suffix <shortsha>`; rollback = update to previous `sha-` tag (§5.4) |
| Ingress | edge: external, target 8080, HTTPS only (`allowInsecure=false`); services: **internal**, target 8080 |
| Probes | startup + liveness `GET /health/live`; readiness: services `GET /health/ready` (DB), **edge `GET /health/live`** (see 3.4) |
| Secrets | services: `hms-db` (connection string); edge (optional D5): `edge-key` |
| Logs | no Log Analytics; live `az containerapp logs show --follow` (log stream, free) |

Why Consumption-only rather than the default workload-profiles environment: Microsoft Learn (*Azure Container Apps
environments*, Types) says a Consumption-only environment has "no cost associated with the Container Apps environment",
whereas workload-profiles environments carry a Dedicated plan management fee as soon as any Dedicated profile exists
(retail: `Dedicated Plan Management` $0.10/h). A workload-profiles environment with **only** the built-in Consumption
profile is also fee-free per the *Billing* page, so it's an acceptable fallback if Azure refuses the legacy type
(decision D1). Never add a Dedicated profile, private endpoint or planned-maintenance window (each triggers
`Environment Management Hour`/`Private Endpoint`/`Planned Maintenance Hour` at **$0.14/h ≈ $102/month**).

### 3.2 App settings per app

| Setting | edge | identity / patients / scheduling |
|---|---|---|
| `ASPNETCORE_ENVIRONMENT` | `Production` | `Production` |
| `Auth__Supabase__ProjectUrl` | `https://gvgomzogbzbjhlcsimrx.supabase.co` | same |
| `OpenApi__Enabled` | `false` | `false` |
| `Cors__AllowedOrigins__0/1` | `https://medicore-hms-three.vercel.app`, `https://medicore-hms-kakani-devs-projects.vercel.app` | **not set** (CORS only at edge) |
| `ReverseProxy__Clusters__<c>__Destinations__d1__Address` | `https://ca-hms-<c>.internal.<defaultDomain>` (identity, patients, scheduling) and `https://medicore-hms-api.azurewebsites.net` (legacy) | – |
| `ConnectionStrings__HmsDatabase` | – (edge has no DB) | `secretref:hms-db` |
| `Outbox__Dispatcher__Enabled` | – | `true` on scheduling only (monolith's dispatcher off in the same release, Phase 3) |
| `Edge__Key` / `Edge__RequiredKey` | `secretref:edge-key` (D5) | `secretref:edge-key` (D5) |

### 3.3 Service-to-service auth and CORS

- **No service→service calls on the request path** (MICROSERVICES-PLAN §4.1). Only edge → service.
- Edge validates the Supabase JWT (JWKS, issuer, audience `authenticated`, `role=authenticated`) and rate-limits by `sub`,
  then YARP forwards `Authorization` **unchanged**; each service re-validates it and resolves the tenant (Hms.Platform);
  RLS via `hms_api_login` stays the final authority.
- Internal ingress: services have no public endpoint; only apps inside `cae-medicore-hms-dev` can reach them.
  Optional defence-in-depth `X-Hms-Edge-Key` (D5): costs nothing, mainly matters on App Service; recommended to keep
  the code path so the F1 fallback stays safe.
- Edge strips client-sent `X-Hms-*`, blocks `/internal/**` (404), adds `X-Forwarded-*`, `traceparent`, `X-Request-Id`.
- CORS, security headers and `X-Hms-Tenant` exposure only at the edge. Services ignore `Origin`.

### 3.4 Health probes (scale-to-zero safe)

| App | Startup | Liveness | Readiness |
|---|---|---|---|
| services | `/health/live`, period 2 s, failureThreshold 30 (≤60 s to boot) | `/health/live`, period 30 s, failureThreshold 3 | `/health/ready` (DB `SELECT 1`), period 30 s, failureThreshold 3, timeout 5 s |
| edge | same | same | **`/health/live`**, not the aggregate |

The edge's aggregate `/health/ready` (pings every cluster) must **not** be its ACA probe: those calls go through internal
ingress and would keep every service awake → no scale-to-zero → grant burnt in ~2 days. Use the aggregate only in
smoke tests / manual checks. Probes themselves are not billed requests and don't keep a scaled-to-zero app alive
(they only run while a replica exists). No GitHub-cron "keep warm" pinger (it would defeat scale-to-zero; D4).

ACA has no CLI flags for probes, so they're applied with a YAML patch (§3.8 step 6).

### 3.5 Secrets

- `hms-db` = contents of `/home/box/.secrets/medicore-hms-connstr` (already contains `No Reset On Close=true`, added
  earlier today; the commands re-verify it without printing). Set with `az containerapp secret set` **inside the shell**,
  stdout/stderr discarded, never in git, chat, MCP arguments or CI. ACA does not return secret values in `show`
  (only names); values are only readable via `az containerapp secret show`, which we never run.
- Caveat: a value passed as a CLI argument is briefly visible in the box's process list while `az` runs; the box is
  single-user, so acceptable. (No Key Vault: it would be a new paid-meter resource and the CTO excluded it.)
- After a secret change, restart the active revision (`az containerapp revision restart`) — secrets are read at start.

### 3.6 Logging without paid Log Analytics

> **Superseded by §8.3** (CTO, 9 Oct ~18:50 IST): the default is now `LOGS=la`, a Log Analytics workspace
> kept inside the free 5 GB/month with a 0.15 GB/day cap. `LOGS=none` remains the zero-risk option.

- `--logs-destination none` (the CLI default is `log-analytics`, which would auto-create a workspace: 5 GB/month free,
  then **$3.22/GB** ingestion and $0.14/GB-month retention beyond the free period, Central India retail).
- Live tail: `az containerapp logs show -n ca-hms-<svc> -g rg-medicore-hms-dev --follow --tail 100` (console) and
  `--type system` (scaling/probe events). Nothing is retained → for incident evidence, copy the stream to a file on the box.
- Serilog compact JSON to stdout (no PHI, no bodies, ids only) — unchanged.
- Later, if retention is needed: workspace-based App Insights with a **0.15 GB/day cap** and 20 % sampling stays inside
  5 GB/month — separate approval (A12), not part of this rollout.

### 3.7 GHCR pull

Public GHCR images pull anonymously, so container apps need **no registry credentials** (no `--registry-*` flags).
Gotcha (GitHub docs, *Configuring a package's access control and visibility*): a newly published package is **private
by default**, even when linked to a public repo (it inherits permissions, not visibility), and **making a package public
is irreversible**. So after the first push of each of `hms-edge`, `hms-identity`, `hms-patients`, `hms-scheduling`,
Mohith must switch it to Public (approval A4). Images contain no secrets (connection strings are runtime secrets).
Alternative if he declines: keep private + a fine-grained read-only `read:packages` PAT as an ACA registry secret (a
long-lived credential → not recommended).

### 3.8 Exact commands — **DO NOT RUN until approved** (A1–A3, A5)

```bash
# =====================  DO NOT RUN until Mohith approves A1, A2, A3 (and A4 for public images)  =====================
set +x; export PATH=$HOME/.local/bin:$PATH
SUB=6f4c512a-8528-461a-962b-f4f8525223a3; RG=rg-medicore-hms-dev; LOC=centralindia; ENV=cae-medicore-hms-dev
az account set -s $SUB
SHA=<40-hex main sha with green CI gate>; IMG=ghcr.io/kakani-dev

# 0. Cost gate (read-only, re-run on the day)
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Azure%20Container%20Apps'%20and%20armRegionName%20eq%20'centralindia'" \
  | python3 -c "import json,sys;[print(i['meterName'],i['retailPrice'],i['unitOfMeasure']) for i in json.load(sys.stdin)['Items'] if i['skuName'] in ('Standard','Environment')]"
grep -q 'No Reset On Close=true' /home/box/.secrets/medicore-hms-connstr || { echo "connstr missing No Reset On Close"; exit 1; }
for s in edge identity patients scheduling; do docker manifest inspect $IMG/hms-$s:sha-$SHA >/dev/null && echo "$s public+present"; done   # anonymous pull check

# 1. (A1) Register the Container Apps resource provider (free; subscription-level)
az provider register -n Microsoft.App --wait
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.App/locations/$LOC/usages?api-version=2024-03-01" \
  --query "value[?name.value=='ManagedEnvironmentCount']"      # limit must be >= 1, else STOP (quota request, free)
#   Do NOT register Microsoft.OperationalInsights.

# 2. (A2) Environment: Consumption-only, NO Log Analytics
az containerapp env create -g $RG -n $ENV -l $LOC \
  --enable-workload-profiles false \
  --logs-destination none \
  --tags project=medicore-hms env=dev cost=free-grant -o none
az containerapp env show -g $RG -n $ENV --query "{logs:properties.appLogsConfiguration.destination,wp:properties.workloadProfiles,domain:properties.defaultDomain}" -o json
#   expect logs: null/none, wp: null.   If Azure rejects --enable-workload-profiles false (legacy type retired), use the
#   default (true) WITHOUT any --workload-profile-type, and verify only "Consumption" is listed (decision D1).
az resource list -g $RG --query "[].type" -o tsv   # must show NO Microsoft.OperationalInsights/workspaces
DOMAIN=$(az containerapp env show -g $RG -n $ENV --query properties.defaultDomain -o tsv)

# 3. (A2) Internal services
for s in identity patients scheduling; do
  az containerapp create -g $RG -n ca-hms-$s --environment $ENV \
    --image $IMG/hms-$s:sha-$SHA --revision-suffix ${SHA:0:7} --revisions-mode single \
    --ingress internal --target-port 8080 --transport auto \
    --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
    --scale-rule-name http --scale-rule-type http --scale-rule-http-concurrency 20 \
    --env-vars ASPNETCORE_ENVIRONMENT=Production OpenApi__Enabled=false \
               Auth__Supabase__ProjectUrl=https://gvgomzogbzbjhlcsimrx.supabase.co \
    --tags project=medicore-hms service=$s -o none
  # secret: value only inside the shell, output discarded
  az containerapp secret set -g $RG -n ca-hms-$s -o none \
    --secrets "hms-db=$(tr -d '\n' < /home/box/.secrets/medicore-hms-connstr)" >/dev/null 2>&1
  az containerapp update -g $RG -n ca-hms-$s -o none \
    --set-env-vars ConnectionStrings__HmsDatabase=secretref:hms-db
done
az containerapp update -g $RG -n ca-hms-scheduling -o none --set-env-vars Outbox__Dispatcher__Enabled=true   # Phase 3 only

# 4. (A2) Edge (external)
az containerapp create -g $RG -n ca-hms-edge --environment $ENV \
  --image $IMG/hms-edge:sha-$SHA --revision-suffix ${SHA:0:7} --revisions-mode single \
  --ingress external --target-port 8080 --transport auto \
  --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
  --scale-rule-name http --scale-rule-type http --scale-rule-http-concurrency 20 \
  --env-vars ASPNETCORE_ENVIRONMENT=Production OpenApi__Enabled=false \
    Auth__Supabase__ProjectUrl=https://gvgomzogbzbjhlcsimrx.supabase.co \
    Cors__AllowedOrigins__0=https://medicore-hms-three.vercel.app \
    Cors__AllowedOrigins__1=https://medicore-hms-kakani-devs-projects.vercel.app \
    ReverseProxy__Clusters__identity__Destinations__d1__Address=https://ca-hms-identity.internal.$DOMAIN \
    ReverseProxy__Clusters__patients__Destinations__d1__Address=https://ca-hms-patients.internal.$DOMAIN \
    ReverseProxy__Clusters__scheduling__Destinations__d1__Address=https://ca-hms-scheduling.internal.$DOMAIN \
    ReverseProxy__Clusters__legacy__Destinations__d1__Address=https://medicore-hms-api.azurewebsites.net \
  --tags project=medicore-hms service=edge -o none
EDGE=https://$(az containerapp show -g $RG -n ca-hms-edge --query properties.configuration.ingress.fqdn -o tsv)

# 5. (optional D5) edge key, generated on the box, never printed
#   umask 077; openssl rand -base64 32 | tr -d '\n' > /home/box/.secrets/medicore-hms-edge-key
#   for a in edge identity patients scheduling; do az containerapp secret set -g $RG -n ca-hms-$a -o none \
#     --secrets "edge-key=$(cat /home/box/.secrets/medicore-hms-edge-key)" >/dev/null 2>&1; done

# 6. Probes via YAML patch (no CLI flags for probes). Template file in git: infra/azure/aca/probes-<kind>.yaml
#    (contains only properties.template.containers[0].{name,image,probes}; no secrets). Verify after:
az containerapp update -g $RG -n ca-hms-patients --yaml infra/azure/aca/probes-service.yaml -o none
az containerapp show -g $RG -n ca-hms-patients --query "properties.template.containers[0].probes" -o json
az containerapp secret list -g $RG -n ca-hms-patients --query "[].name" -o tsv     # names only: hms-db must still be there

# 7. Verify (read-only)
curl -s $EDGE/health/live; for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " $EDGE/health/ready; done
curl -s -o /dev/null -D - -X OPTIONS -H "Origin: https://medicore-hms-three.vercel.app" \
  -H "Access-Control-Request-Method: POST" $EDGE/api/v1/me | grep -i access-control-allow-origin
curl -s -o /dev/null -w "%{http_code}\n" https://ca-hms-patients.internal.$DOMAIN/health/live   # from the box: must FAIL (internal only)
WEB_URL=https://medicore-hms-three.vercel.app API_URL=$EDGE PUBLISHABLE_KEY=<publishable key, as in deploy-azure.md> \
  scripts/smoke/deploy-smoke.sh            # + Sprint 2 smoke: booking, check-in, queue
az resource list -g $RG --query "[].{n:name,t:type}" -o table   # exactly: F1 plan, F1 site, 1 managedEnvironment, 4 containerApps
# ======================================================================================================================
```

`probes-service.yaml` (to be committed with the deploy PR; illustrative):

```yaml
properties:
  template:
    containers:
      - name: ca-hms-patients
        image: ghcr.io/kakani-dev/hms-patients:sha-<sha>
        probes:
          - { type: Startup,   httpGet: { path: /health/live,  port: 8080 }, periodSeconds: 2,  failureThreshold: 30 }
          - { type: Liveness,  httpGet: { path: /health/live,  port: 8080 }, periodSeconds: 30, failureThreshold: 3 }
          - { type: Readiness, httpGet: { path: /health/ready, port: 8080 }, periodSeconds: 30, failureThreshold: 3, timeoutSeconds: 5 }
```
(Before relying on `--yaml` updates, confirm in a dry run on the first app that secrets/env/scale survive the patch; if not,
create the apps from a full YAML rendered into `/dev/shm` with the secret injected by the shell, then `shred -u` it.)

### 3.9 Deploy from the box (default until A6)

```bash
# DO NOT RUN until the environment exists and Mohith approved the deploy
az containerapp update -g rg-medicore-hms-dev -n ca-hms-<svc> \
  --image ghcr.io/kakani-dev/hms-<svc>:sha-<sha> --revision-suffix <shortsha> -o none
```

### 3.10 GitHub Actions OIDC (optional, approval A6 — creates an Entra identity)

Needs an **Entra app registration** (or a user-assigned managed identity) with a **federated credential** and an
**RG-scoped role assignment**. All three are identity/permission changes ⇒ Mohith's explicit approval. No client secret
is ever created; the workflow gets a short-lived token.

```bash
# =====================  DO NOT RUN until Mohith approves A6  =====================
APP_ID=$(az ad app create --display-name gh-medicore-hms-aca-deploy --query appId -o tsv)
az ad sp create --id $APP_ID -o none
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "gh-env-aca-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:kakani-dev/hospital-management-system:environment:aca-dev",
  "audiences": ["api://AzureADTokenExchange"]}'
# Least privilege: built-in "Container Apps Contributor" on the RG only (not Contributor, not subscription)
az role assignment create --assignee $APP_ID --role "Container Apps Contributor" \
  --scope /subscriptions/6f4c512a-8528-461a-962b-f4f8525223a3/resourceGroups/rg-medicore-hms-dev
# GitHub: environment "aca-dev" (required reviewer Mohith, deployment branch = main) with VARIABLES (not secrets):
#   AZURE_CLIENT_ID=$APP_ID  AZURE_TENANT_ID=ab1a6103-6bda-47b9-8f1b-3bab684f84e3  AZURE_SUBSCRIPTION_ID=6f4c512a-...
# Workflow: permissions id-token: write; azure/login@<sha> with client-id/tenant-id/subscription-id.
# ===================================================================================
```
The subject pins the token to the `aca-dev` environment, so a PR or another branch can't deploy.

---

## 4. Cost analysis

### 4.1 Sources (queried 9 Oct 2026, ~18:30 IST)

- Microsoft Learn, *Billing in Azure Container Apps*: per subscription per calendar month free:
  **180,000 vCPU-seconds, 360,000 GiB-seconds, 2,000,000 HTTP requests**; scaled to zero ⇒ no resource charges;
  only requests from **outside** the environment are billable; **health probe requests are not billable**;
  Dedicated plan management fee only with a Dedicated profile; private endpoints / planned maintenance incur it regardless.
- Microsoft Learn, *Azure Container Apps environments*: Consumption-only (legacy) environment: "no cost associated with
  the Container Apps environment"; environments idle for **> 90 days are automatically deleted**.
- Microsoft Learn, *Log storage and monitoring options*: destinations `log-analytics` (CLI default), `azure-monitor`, `none`.
- Azure Retail Prices API (`prices.azure.com/api/retail/prices`, `armRegionName eq 'centralindia'`, USD):

| Meter | Price |
|---|---|
| ACA Standard vCPU Active | $0.000024 / vCPU-s |
| ACA Standard vCPU Idle | $0.000003 / vCPU-s |
| ACA Standard Memory Active / Idle | $0.000003 / GiB-s |
| ACA Standard Requests | $0.40 / million |
| ACA Environment Management / Private Endpoint / Planned Maintenance Hour | $0.14 / h each (avoid) |
| ACA Dedicated Plan Management | $0.10 / h (avoid) |
| Log Analytics ingestion | first 5 GB/month $0, then $3.22 / GB; retention $0.14 / GB-month (beyond included) |
| Container Registry Basic / Standard | $0.1666 / day (~$5/month) / $0.6666 / day (not used) |
| Bandwidth, internet egress | first 100 GB/month $0, then $0.11–0.12 / GB |

### 4.2 Fit of the free grant

At 0.25 vCPU / 0.5 GiB per replica, both grants give exactly **720,000 replica-seconds = 200 replica-hours/month**,
shared by all apps in the subscription (no other project in this subscription uses ACA today).
Active overage = 0.25×3600×$0.000024 + 0.5×3600×$0.000003 = **$0.027 per replica-hour**; idle (only when min ≥1) ≈ $0.0081.

Scale-in after the last request takes the HTTP scaler's cool-down (default 300 s), so each wake-up of an app costs at
least ~5–6 minutes of replica time. A typical demo touches edge + 1–2 services.

| Scenario (4 apps, max 1 replica each) | Replica-h / month | Est. cost |
|---|---|---|
| Light dev/demo: edge + 2 services awake ~1.5 h/day, 22 days | ~100 | **$0** |
| Each of 4 apps awake ~2 h/day, 22 days | ~176 | **$0** (≈ 88 % of grant) |
| Each of 4 apps awake ~2 h/day, 30 days | ~240 | ≈ 40 × $0.027 ≈ **$1.08** |
| Office hours, 9 h/day × 22 days, all 4 apps | ~792 | ≈ **$16** |
| Edge kept warm (min 1, idle 24×7) + services scale-to-zero | ~730 edge + services | ≈ **$4–5** (D4, paid) |
| All 4 warm 24×7 (min 1) | 2,920 | ≈ **$22** |

Requests: only browser → edge requests count; a demo month is a few thousand to tens of thousands ≪ 2 M ⇒ $0.
Egress: Supabase traffic + responses ≪ 100 GB ⇒ $0.

Cold starts: container pull (cached on node after first) + .NET start + JWKS fetch + first DB connection; expected
"seconds", **not yet measured** for our images. Worst case is a chained cold start (edge + service). Target to measure in
the first deploy: p50/p95 of first request after ≥10 min idle; acceptance ≤ 15 s p95 (vs 30–60 s on F1 today).

### 4.3 What could cost money (and the guardrail)

| Risk | Guardrail |
|---|---|
| Log Analytics workspace auto-created by `env create` default | `--logs-destination none`; verify `az resource list` shows no workspace; don't register `Microsoft.OperationalInsights` |
| ACR | not used; GHCR public |
| Dedicated workload profile / private endpoint / planned maintenance ($0.10–0.14/h each) | Consumption-only env; never pass `--workload-profile-*`, no VNet/PE; RG budget alert |
| Exceeding the grant (warm replicas, scale-out, keep-warm pingers, edge readiness probe fanning out) | `min 0`, `max 1`, edge readiness = `/health/live`, no cron pinger, sizes 0.25/0.5 |
| Egress > 100 GB | not plausible at demo scale; budget alert |
| A second environment / extra apps (e.g. legacy as 5th app) | each extra app shares the same 200 replica-h — decision D2 |
| Budget alert lag | Cost Management data lags ~8–24 h; a budget **alerts, it does not stop** spend |

Budget ($0 to create; approval A3). RG scope so other projects in the subscription don't trigger it:

```bash
# DO NOT RUN until approved (A3)
az rest --method put \
  --url "https://management.azure.com/subscriptions/6f4c512a-8528-461a-962b-f4f8525223a3/resourceGroups/rg-medicore-hms-dev/providers/Microsoft.Consumption/budgets/medicore-hms-1usd?api-version=2023-05-01" \
  --body '{"properties":{"category":"Cost","amount":1,"timeGrain":"Monthly",
    "timePeriod":{"startDate":"2026-10-01T00:00:00Z","endDate":"2027-09-30T00:00:00Z"},
    "notifications":{
      "actual50":{"enabled":true,"operator":"GreaterThan","threshold":50,"contactEmails":["kakanimohith566@gmail.com"],"thresholdType":"Actual"},
      "actual100":{"enabled":true,"operator":"GreaterThan","threshold":100,"contactEmails":["kakanimohith566@gmail.com"],"thresholdType":"Actual"},
      "forecast100":{"enabled":true,"operator":"GreaterThan","threshold":100,"contactEmails":["kakanimohith566@gmail.com"],"thresholdType":"Forecasted"}}}}' -o none
```

Optional extra guardrail (free, approval A10): Azure Policy "Allowed resource types" on `rg-medicore-hms-dev` limited to
`Microsoft.Web/serverFarms`, `Microsoft.Web/sites`, `Microsoft.App/managedEnvironments`, `Microsoft.App/containerApps`
— blocks an accidental workspace/ACR/Key Vault in that RG.

### 4.4 Is a card / payment method needed?

**No card needs to be attached — but charges are real.** The subscription's offer is **Pay-As-You-Go
(`quotaId PayAsYouGo_2014-09-01`) with `spendingLimit: Off`**. A PAYG subscription only exists with a payment method
already on file, so Container Apps can be created without adding anything, and **any usage above the free grant is billed
automatically to that payment method with no cap**. (A Free Trial subscription would instead show a `FreeTrial_*` quota
id with `spendingLimit: On` and $200 credit, which stops resources when exhausted — that is **not** this subscription.)
The ACA monthly free grant applies per subscription to PAYG. Hence the guardrails above matter: they are the only thing
between a misconfiguration and a bill.

Also note the 90-day rule: an environment idle (no active apps) for 90 days is auto-deleted by Azure — harmless (it's
free to recreate) but the runbook must be repeatable (it is: §3.8).

---

## 5. Migration from App Service F1 + Vercel

Prerequisites: hosted DB at the Sprint 2 level (`20261009090000` + `20261010090000…090400`; **still awaiting Mohith's
confirmation in chat, not covered by this plan**), Phase 0 merged (per-service images build in CI), edge exists (Phase 1).
Render: **paused, stays untouched**; not part of cutover or rollback (its env var is stale and lacks `No Reset On Close`).

### 5.1 Cutover order

1. Approvals A1–A5 in hand. Images for `sha-<S>` green and public.
2. Create env + 4 apps (§3.8). Edge catch-all → F1 monolith; route table initially sends **everything** to legacy
   (Phase 1 behaviour), so ACA only adds the edge hop.
3. Verify the edge directly: live/ready, CORS preflight from both Vercel origins, `deploy-smoke.sh` with `API_URL=<edge>`,
   Sprint 2 smoke (booking, check-in, queue), measure cold start.
4. **Vercel Preview first**: set `VITE_API_BASE_URL=<edge>` for **Preview** only, redeploy a preview from `main`, run the
   smoke against the preview URL (add the preview origin to edge CORS temporarily if it differs).
5. **Production (approval A7)**: set `VITE_API_BASE_URL` (Production) to the edge URL (Vercel env id `bRNJQfk3oz8GvmNZ`,
   project `medicore-hms`), **redeploy production from `main`** (Vite inlines `VITE_*` at build time), confirm the live bundle
   contains the edge host and 0 `azurewebsites` references, re-run smoke.
6. Flip edge routes service by service (Phase 2 patients → 3 scheduling → 4 identity) — config + restart of the edge only.
7. F1 stays running (as the legacy upstream and fallback) until **ACA is proven**: ≥7 days, ≥3 green smokes on different
   days, cold-start p95 within target, $0 in Cost Management for `rg-medicore-hms-dev`, zero catch-all hits for 1 week
   after Phase 4. Only then propose stopping (not deleting) F1 (approval A13).

### 5.2 Rollback

| Failure | Rollback | Time |
|---|---|---|
| Edge/ACA broken after step 5 | Vercel `VITE_API_BASE_URL` back to `https://medicore-hms-api.azurewebsites.net`, redeploy production | ~2 min |
| One extracted service broken | edge route for that prefix back to `legacy` (env var / config) + `az containerapp revision restart` on edge | ~1 min |
| Bad image | `az containerapp update --image …:sha-<previous>` (single revision mode) or `svc-<name>.yml` dispatch | ~1 min |
| Unexpected cost | `az containerapp update --min-replicas 0 --max-replicas 0`… (or `az containerapp revision deactivate`), then investigate; delete env only with approval | minutes |

The DB is shared and unchanged by cutover, so rollback never involves data.

---

## 6. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Env type: Consumption-only (legacy, explicitly no env cost) vs default workload-profiles with only Consumption | Consumption-only; fall back to WP-Consumption if Azure rejects it |
| D2 | Legacy monolith upstream during Phases 1–5: existing F1 app vs a 5th ACA app | F1 (no extra grant use; it's the fallback anyway); accept its 30–60 s cold start on catch-all routes |
| D3 | Deploy mechanism: az CLI from the box vs GitHub OIDC | Box first; OIDC after ACA is proven (A6) |
| D4 | Cold starts: accept scale-to-zero vs edge `min 1` (~$4–5/month, paid) | Accept; measure first |
| D5 | `X-Hms-Edge-Key` on ACA (internal ingress already isolates) | Keep (free, keeps F1 fallback safe) |
| D6 | GHCR public packages vs private + PAT | Public (no credential to manage) |
| D7 | Custom domain + free managed cert (e.g. `api.<domain>`) so the web URL never changes | Later; ACA FQDN is fine for demo |
| D8 | Keep the Jenkinsfile mirror | Mirror the matrix, non-required (as MICROSERVICES-PLAN §9.8) |
| D9 | Merge queue | Not now; `merge_group` trigger is included so it can be turned on later |

## 7. Approval checklist for Mohith

| # | Item | Cost | Reversible? |
|---|---|---|---|
| A1 | Register `Microsoft.App` resource provider on the subscription | $0 | yes (unregister) |
| A2 | Create `cae-medicore-hms-dev` (Consumption-only, logs none) + 4 container apps in `rg-medicore-hms-dev`, Central India | $0 inside grant; **overage billed to the PAYG card on file, no spending cap** | yes (delete) |
| A3 | RG budget `medicore-hms-1usd` ($1/month, emails at 50 %/100 % actual, 100 % forecast to kakanimohith566@gmail.com) | $0 | yes |
| A4 | Make GHCR packages `hms-edge`, `hms-identity`, `hms-patients`, `hms-scheduling` **public** | $0 | **no** (public is permanent) |
| A5 | Put the Supabase connection string into ACA secrets (`hms-db`) on the 3 service apps (from the box file, never echoed) | $0 | yes |
| A6 | (optional) Entra app registration `gh-medicore-hms-aca-deploy` + federated credential (env `aca-dev`) + `Container Apps Contributor` on the RG; GitHub environment `aca-dev` with Mohith as required reviewer | $0 | yes |
| A7 | Change Vercel `VITE_API_BASE_URL` (Preview, then Production) to the edge URL and redeploy production | $0 | yes (~2 min) |
| A8 | Branch protection: add `CI gate` (S2), later replace the 4 names with `CI gate` (S3) — Mohith runs the `gh api` commands in §1.6 | $0 | yes |
| A9 | Repo settings: secret scanning + push protection, Dependabot alerts/updates, code scanning SARIF uploads | $0 (public repo) | yes |
| A10 | (optional) Azure Policy "Allowed resource types" on `rg-medicore-hms-dev` | $0 | yes |
| A11 | Hosted Supabase migration creating per-service login roles (Phase 2) + their generated passwords | $0 | yes (drop roles) |
| A12 | (later, optional) App Insights with 0.15 GB/day cap | $0 inside 5 GB | yes |
| A13 | (later) stop then delete F1 `medicore-hms-api`; separately, any Render deletion | $0 | stop yes / delete no |

Not in this plan and still separately pending: the hosted Sprint 2 DB apply (`20261009090000` + `20261010090000…090400`),
which waits for Mohith's confirmation in chat.

---

## 8. Deploy artifacts (added 9 Oct 2026 ~19:15 IST; still PREP ONLY)

Nothing below has been run against Azure. Validation done on the box: `bash -n` + `shellcheck` clean for both
scripts, `actionlint` clean for the workflow, and `deploy-aca.sh` was exercised end-to-end against **stub** `az`/`curl`
binaries (fake responses, fake secret files) to check control flow, idempotency branches, the pool rewrite
(`Maximum Pool Size=5`) and that no secret reaches stdout.

| File | Purpose |
|---|---|
| `infra/aca/deploy-aca.sh` | Idempotent create/update of the environment + 4 apps. Refuses without `APPROVED=1` (banner, exit 2) and refuses under `set -x`. |
| `scripts/smoke/smoke-gateway.sh` | Gateway smoke: public checks (`SMOKE_AUTH=0`), + sign-in and `/me` (default), + writes (`SMOKE_WRITE=1`). |
| `.github/workflows/deploy-aca.yml` | **DRAFT**, inert unless repo variable `ACA_DEPLOY_ENABLED == 'true'`. Build+push to GHCR, OIDC login, `az containerapp update --image`, public smoke. |

### 8.1 `infra/aca/deploy-aca.sh`

```
APPROVED=1 IMAGE_SHA=<40-hex> [LOGS=la|none] [POOL_SIZE=5] bash infra/aca/deploy-aca.sh
```

Order of steps (each one stops the script on failure):
0. Subscription/RG check; **cost gate**: live retail prices for ACA Standard meters must match the plan (vCPU active
   $0.000024/s, memory $0.000003/GiB-s, requests $0.40/M); with `LOGS=la`, Log Analytics' first ingestion tier must be
   $0 and `cap × 31 ≤ 4.9 GB`.
1. **Provider + quota check, no registration**: stops if `Microsoft.App` (or, for `LOGS=la`,
   `Microsoft.OperationalInsights`) is not `Registered`, or if `ManagedEnvironmentCount` has no headroom.
2. Local secrets: connection string must contain `No Reset On Close=true` (warns if not port 6543); edge key generated
   with `secrets.token_urlsafe(48)` (48 random bytes → 64 chars) into `/home/box/.secrets/medicore-hms-edge-key`
   **only if missing**, `chmod 600`. The service connection string is derived in memory with any
   `Maximum Pool Size` replaced by `POOL_SIZE` (default 5).
3. Images: anonymous GHCR token + manifest HEAD for `hms-{edge,identity,patients,scheduling}:sha-<IMAGE_SHA>` (proves
   the packages are public and present).
4. `LOGS=la`: workspace `log-medicore-hms-dev` (PerGB2018, retention 30 d, `--quota 0.15`), verified sku + cap;
   environment `cae-medicore-hms-dev` with `--enable-workload-profiles false` and the workspace (key fetched inside the
   shell, all output discarded). `LOGS=none`: `--logs-destination none`. An existing environment is switched to the
   requested destination. Fails if any workload profile exists.
5. Services `ca-hms-{identity,patients,scheduling}`: internal ingress + `--allow-insecure` (HTTP only inside the
   environment), secrets `hms-db`, `hms-edge-key`; then an ARM **PATCH** of `properties.template` (image, env, 0.25/0.5Gi,
   startup/liveness `/health/live`, readiness `/health/ready`, scale 0..1 HTTP 20) which creates no new revision when nothing
   changed; then verifies the secret **names** survived.
6. Edge `ca-hms-edge`: external ingress, secret `hms-edge-key`, readiness `/health/live` (not the aggregate), CORS
   indices 0–2 overwritten (env vars merge by index; leaving index 2 would keep `http://localhost:4173` from
   `appsettings.json` in production), YARP destinations
   `ReverseProxy__Clusters__<svc>__Destinations__primary__Address=http://ca-hms-<svc>/`.
7. Post-checks: resource types in the RG (fails on registries / vaults / App Insights components / workload profiles),
   waits ≤90 s for edge `/health/live`, prints `GATEWAY_URL=https://ca-hms-edge.<env-domain>`.

App settings set on every app: `ASPNETCORE_ENVIRONMENT=Production`, `OpenApi__Enabled=false`,
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, `Auth__Supabase__ProjectUrl=https://gvgomzogbzbjhlcsimrx.supabase.co`,
`Edge__Key=secretref:hms-edge-key`. Services add `ConnectionStrings__HmsDatabase=secretref:hms-db`,
`Database__MaxPoolSize=5`, `Outbox__Dispatcher__Enabled=false` (publisher is log-only; the F1 monolith's dispatcher is
also off today — turn it on in scheduling only when a consumer exists, MICROSERVICES-PLAN §4.2).

### 8.2 What the code expects (and what's missing)

Found in the **uncommitted** worktree `/workspace/hms-wt/ms-services` (branch `ms/services`, base `1306b8a`; none of
this is on `main` or pushed):

| Concern | Code | Config / env var |
|---|---|---|
| Edge adds the key | `EdgeHost` YARP transform strips every client `X-Hms-*` header, then adds `X-Hms-Edge-Key`; `UpstreamProbe` adds it on readiness calls | `Edge:Key` → **`Edge__Key`** |
| Services require it | `Hms.Platform.Http.EdgeKeyMiddleware` via `ServiceDefaults` (`UseHmsEdgeKey`): every path except `/health/*` needs the header (constant-time compare), else bare **404**; empty key disables the check | `Edge__Key` |
| YARP destinations | `appsettings.json` clusters `identity`, `patients`, `scheduling`, destination name **`primary`** | `ReverseProxy__Clusters__<svc>__Destinations__primary__Address` |
| CORS | `EdgeCors`: exact `Cors:AllowedOrigins` + anchored `Cors:AllowedOriginPatterns` (`https://medicore-hms-[a-z0-9-]+-kakani-devs-projects\.vercel\.app`) | `Cors__AllowedOrigins__0..2` |
| Pool size | `Hms.Platform.Persistence.HmsDatabase`: forces `No Reset On Close=true` unless set; `Database:MaxPoolSize` overrides the pool | **`Database__MaxPoolSize`** (the script also rewrites the string, so pre-`HmsDatabase` images get 5 too) |
| Edge health | `/health/live` (self), `/health/ready` (aggregate over clusters), `/api/v1/warmup` (anonymous, 6/min/IP, called by the web app after sign-in to wake services) | – |

**Missing / to fix before deploy day:**
1. **No `backend/edge/Dockerfile`** → `hms-edge` image can't be built (the workflow and script reference it).
2. All of the above (edge, `EdgeKeyMiddleware`, `HmsDatabase`, service Dockerfiles) is only in uncommitted local
   worktrees (`ms-services`, partly `ms-phase0`); it needs its own PR, Code Review and green CI first.
3. No CI job publishes images to GHCR yet; first publication creates **private** packages (approval A4 to make public).
4. The edge has **no legacy catch-all**: unknown `/api/v1/*` → 404. So the ACA cutover moves *all* routes to the services
   at once (the F1 monolith is not behind the edge). That is a bigger step than the strangler in MICROSERVICES-PLAN §12;
   the rollback (Vercel back to F1) still works because the DB is shared.
5. `/api/v1/warmup` after every sign-in wakes all three services → each sign-in costs ≈3 × 5–6 replica-minutes
   (≈0.3 replica-hours). Included in §8.4.
6. The "service rejects a request without the edge key" check can't be run from outside (internal ingress; chiseled/ASP.NET
   images have no shell/curl for `az containerapp exec`). Covered by unit tests; noted in the smoke output.

### 8.3 Log Analytics: `none` vs workspace with a cap (`LOGS=la` default)

| | `LOGS=none` | `LOGS=la` (default) |
|---|---|---|
| What's kept | nothing; live `az containerapp logs show --follow` only | console + system logs, queryable (KQL), 30 days |
| Resource | none | `log-medicore-hms-dev`, PerGB2018, retention 30 d, `dailyQuotaGb=0.15` |
| Price (Central India retail + Azure Monitor pricing page) | $0 | ingestion **first 5 GB/month per billing account free**, then $3.22/GB; **31 days of analytics retention included** (we keep 30) |
| Worst case | $0 | cap 0.15 GB/day × 31 = **4.65 GB/month < 5 GB**. Microsoft Learn (*Set daily cap*): collection stops at the cap until the workspace's (non-configurable) reset hour, but "the daily cap can't stop data collection at precisely the specified cap level… If data is collected above the cap, it's still billed." So the realistic risk is **log loss** after ~0.15 GB on a bad day, plus a small overshoot that could be billed only if the month's total also exceeds 5 GB |
| Extra approval | – | register `Microsoft.OperationalInsights` (A1b) |
| Shared free tier | – | 5 GB is per **billing account**: this subscription is the only one visible and has **no** workspaces or App Insights today; a future workspace elsewhere on the same billing account would share the 5 GB |

Expected volume at demo scale: Serilog compact JSON request logs ≈0.5–1 KB/request + ACA system events; even
10,000 requests/day ≈ 10 MB/day ≈ 0.3 GB/month — about 6 % of the free tier. Queries on Analytics tables are free
(the "Data Analyzed" meter applies to Basic/Auxiliary tables, which we don't use). Don't enable App Insights here (A12).

### 8.4 Cost check (recomputed with Log Analytics)

Sources: Microsoft Learn *Billing in Azure Container Apps* (free grant per subscription per calendar month:
**180,000 vCPU-s, 360,000 GiB-s, 2,000,000 requests**; scaled-to-zero = no charge; only requests from outside the
environment and not health probes are billable); Azure Retail Prices API, `armRegionName eq 'centralindia'`, queried
9 Oct 2026 (ACA vCPU active $0.000024/s, idle $0.000003/s, memory $0.000003/GiB-s, requests $0.40/M; Log Analytics
ingestion 0–5 GB $0 then $3.22/GB; bandwidth internet egress first 100 GB/month $0); Azure Monitor pricing page
("first 5 GB/month per billing account… free"); Microsoft Learn *Set daily cap*; GitHub Docs (GHCR: public container
packages pull anonymously; Actions minutes and Packages storage/transfer are free for public repositories).

| Line | Demo-scale usage (4 apps, 0.25 vCPU/0.5 GiB, min 0/max 1) | Free allowance | Cost |
|---|---|---|---|
| ACA vCPU-s | ~176 replica-h × 900 vCPU-s = 158,400 | 180,000 | $0 |
| ACA GiB-s | ~176 replica-h × 1,800 GiB-s = 316,800 | 360,000 | $0 |
| ACA requests | ≤50,000 (browser → edge only; edge→service and probes not billed) | 2,000,000 | $0 |
| ACA environment | Consumption-only, no workload profile / PE / maintenance window | no environment fee | $0 |
| Log Analytics | ≤0.3 GB ingested, 30 d retention; hard-ish cap 4.65 GB | 5 GB + 31 d | $0 |
| Egress | ≪1 GB (API JSON + Supabase traffic) | 100 GB | $0 |
| Registry | GHCR public | free | $0 |
| CI/CD | GitHub Actions on a public repo | free | $0 |
| Budget alert | Cost Management budget | free | $0 |

"~176 replica-h" = each of 4 apps awake ~2 h/day on 22 days. With warmup-after-sign-in (§8.2 #5) that's ≈ 30 sign-in
sessions/day spread out, or fewer longer sessions.

**Verdict: $0 confirmed for demo usage, with conditions.** Charges start when any of these happens:
- total replica time exceeds ~200 replica-hours/month at 0.25/0.5 (e.g. all 4 apps awake 2 h/day every day = 240 h ≈
  **$1.08**; office-hours use ≈ $16; anything with `min-replicas ≥ 1` ≈ $4–5 per app per month idle);
- anyone raises CPU/memory (0.5/1.0 Gi halves the free hours) or `max-replicas`;
- a Dedicated workload profile, private endpoint or planned-maintenance window is added ($0.10–0.14/h ≈ $73–102/month);
- Log Analytics ingestion passes 5 GB in a month (cap prevents this except for overshoot) or retention is raised above 31 d;
- an ACR, Key Vault, App Insights or a second workspace is created;
- egress passes 100 GB/month;
- a keep-warm pinger or the edge aggregate `/health/ready` is used as a probe.

**The subscription is Pay-As-You-Go (`PayAsYouGo_2014-09-01`) with `spendingLimit: Off`.** The payment method on file
is charged automatically for any overage, with no cap; the $1 budget only emails (with ~8–24 h data lag).

### 8.5 `hms_api_login` connection limit (needs a decision)

Facts: `hms_api_login` has `CONNECTION LIMIT 20` (runbook `deploy-sprint-2-hosted.md`); the box connection string uses
the Supavisor **transaction** pooler (port 6543) with `Maximum Pool Size=10`; the F1 app was configured from the same
file, so it holds up to 10.

| Setup | Client connections (app pools → Supavisor) |
|---|---|
| F1 alone (today) | 10 |
| ACA alone | 3 × 5 = 15 |
| **F1 + ACA overlap (cutover window)** | **10 + 15 = 25 > 20** |

Nuance: through :6543, app pools are *Supavisor clients* (200 allowed on Nano); the role's CONNECTION LIMIT applies to
Supavisor's **server** connections to Postgres, which Supavisor caps at its pool size (15 per user+db per
`pr1-review-answers.md` §5). So 25 client connections would normally be multiplexed onto ≤15 server connections and not
hit the limit. It **does** bite if anything connects in session mode (:5432 via Supavisor) or directly, or if
Supavisor's pool size is raised. Options:
- **Recommended:** during the overlap, lower F1 to `Maximum Pool Size=5` (10 + … → 5 + 15 = 20). This changes the live F1
  app setting = approval **A15** (command below, not run).
- Or raise the limit (e.g. `alter role hms_api_login connection limit 30;`) — a hosted DB write = approval **A14**.
- Long term, per-service login roles (A11) give each service its own limit.

```bash
# DO NOT RUN until A15 is approved (changes the live F1 app; value built in the shell, never printed)
az webapp config appsettings set -g rg-medicore-hms-dev -n medicore-hms-api -o none --settings \
  ConnectionStrings__HmsDatabase="$(tr -d '\n' < /home/box/.secrets/medicore-hms-connstr | sed -E 's/Maximum Pool Size=[0-9]+/Maximum Pool Size=5/')" >/dev/null 2>&1
```

### 8.6 `scripts/smoke/smoke-gateway.sh`

1. Gateway `/health/live` with up to 90 s cold-start retries.
2. Per-service readiness through the gateway's **aggregate** `/health/ready` (the gateway doesn't route individual
   services' `/health/*`). Calling it wakes all three services — fine for a smoke run, never as the edge's ACA probe.
3. CORS preflight: the Vercel origin is allowed, `https://evil.example` is not.
4. Isolation: `https://ca-hms-<svc>.internal.<env-domain>/health/live` from the box must not return 200/3xx (ACA
   answers 404 to outside callers); `/internal/**` at the gateway → 404. The edge-key rejection is printed as a NOTE
   (not testable from outside, §8.2 #6).
5. (default) Demo admin sign-in with the password from `/home/box/.secrets/medicore-demo-admin`; the token is held in a
   600 temp header file (`curl -H @file`), never on a command line or printed.
6. `GET /api/v1/me` with 90 s cold-start tolerance and a spoofed client `X-Hms-Edge-Key` (must be stripped, still 200).
7. (`SMOKE_WRITE=1`) patient create + search, then the Sprint 2 flow reused from `deploy-smoke-sprint2.sh`: practitioner,
   schedule, slots, book, check in, queue board, in_consultation → done, walk-in + cancel.

### 8.7 `.github/workflows/deploy-aca.yml` (DRAFT)

`plan` (resolve sha + matrix; ordered identity, patients, scheduling, edge) → `image` (matrix, `packages: write`,
buildx with GHA cache, SBOM + provenance, tag `sha-<40hex>`) → `deploy` (matrix, `max-parallel: 1`, `environment: aca-dev`,
`id-token: write`, `azure/login@v2` OIDC with secrets `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID`,
`az containerapp update --image` only) → `smoke` (`SMOKE_AUTH=0`, no secrets). Triggers: `workflow_dispatch` (sha, services)
and `workflow_run` of `CI` on `main` (only when it concluded `success` for a `push`). Workflow-level
`concurrency: deploy-aca` and per-service groups, never cancelling. **Every job** is gated on
`vars.ACA_DEPLOY_ENABLED == 'true'`.

---

## 9. Deploy day (exact order)

Preconditions: hosted DB at the Sprint 2 level (separate approval, still pending); the services/edge PR merged with
green CI (incl. `backend/edge/Dockerfile`); images for one `main` sha pushed to GHCR.

1. **Approvals** — Mohith signs off the checklist below (at least A1, A2, A3, A4, A5, A7; A1b if `LOGS=la`; A14 or A15).
2. **Budget first** (A3): create the $1 RG budget (§4.3 command).
3. **Provider registration** (A1/A1b):
   `az provider register -n Microsoft.App --wait` and, for `LOGS=la`, `az provider register -n Microsoft.OperationalInsights --wait`.
4. **Quota check** (read-only): `az rest --method get --url "https://management.azure.com/subscriptions/6f4c512a-8528-461a-962b-f4f8525223a3/providers/Microsoft.App/locations/centralindia/usages?api-version=2024-03-01" --query "value[?name.value=='ManagedEnvironmentCount']"`
   — limit must be ≥1 (otherwise stop and request quota; free).
5. **Connection budget** (A15 or A14): lower F1's pool to 5, or raise the role limit.
6. **Packages public** (A4): set `hms-edge`, `hms-identity`, `hms-patients`, `hms-scheduling` to Public (irreversible).
7. **Run the script**: `APPROVED=1 IMAGE_SHA=<sha> LOGS=la bash infra/aca/deploy-aca.sh` → note `GATEWAY_URL`.
8. **Smoke**: `GATEWAY_URL=… PUBLISHABLE_KEY=<public key> bash scripts/smoke/smoke-gateway.sh` (read-only), then with
   `SMOKE_WRITE=1` after the CTO's go. Record cold-start seconds.
9. **Vercel switch** (A7): `VITE_API_BASE_URL` = `GATEWAY_URL` for Preview → redeploy a preview → smoke against it →
   Production → redeploy production from `main` → bundle check (gateway host present, no `azurewebsites`) → smoke again.
10. **Watch**: Cost Management for `rg-medicore-hms-dev` daily for a week; F1 stays as fallback (rollback = Vercel env
    back to `https://medicore-hms-api.azurewebsites.net` + redeploy). Render stays paused and untouched.
11. **Later**: A6 (OIDC) + set `ACA_DEPLOY_ENABLED=true` to turn on `deploy-aca.yml`; A8 branch protection; A13 F1 retirement.

### 9.1 Approval checklist (complete; supersedes §7)

| # | Item | Cost | Reversible |
|---|---|---|---|
| A1 | Register `Microsoft.App` on the subscription | $0 | yes |
| A1b | Register `Microsoft.OperationalInsights` (only for `LOGS=la`) | $0 | yes |
| A2 | Create `cae-medicore-hms-dev` (Consumption-only) + 4 container apps in `rg-medicore-hms-dev`, Central India | $0 in grant; overage billed to PAYG card, no cap | yes |
| A2b | **Log Analytics choice**: `LOGS=la` (workspace `log-medicore-hms-dev`, PerGB2018, 30 d, 0.15 GB/day cap; $0 inside 5 GB, risk = log loss on a heavy day) **or** `LOGS=none` (no stored logs, zero risk) | $0 | yes |
| A3 | $1/month budget on `rg-medicore-hms-dev` with email alerts | $0 | yes |
| A4 | Make the 4 GHCR packages public | $0 | **no** |
| A5 | Store the DB connection string (pool 5) and the generated edge key as ACA secrets | $0 | yes |
| A6 | Entra app + federated credential (`environment:aca-dev`) + `Container Apps Contributor` on the RG; GitHub environment `aca-dev` (Mohith as reviewer); secrets `AZURE_*`; repo variable `ACA_DEPLOY_ENABLED=true` | $0 | yes |
| A7 | Vercel `VITE_API_BASE_URL` → gateway URL (Preview, then Production) + production redeploy | $0 | yes (~2 min) |
| A8 | Branch protection: add `CI gate`, later replace the 4 names | $0 | yes |
| A9 | Repo security settings (secret scanning/push protection, Dependabot, code scanning) | $0 | yes |
| A10 | (optional) Azure Policy allowed resource types on the RG | $0 | yes |
| A11 | (Phase 2) per-service DB login roles on hosted Supabase | $0 | yes |
| A12 | (optional, later) App Insights | $0 in 5 GB | yes |
| A13 | (later) stop then delete F1 | $0 | stop yes / delete no |
| A14 | **`hms_api_login` CONNECTION LIMIT**: raise 20 → e.g. 30 (hosted DB write) — *or* A15 | $0 | yes |
| A15 | Lower the live F1 app's `Maximum Pool Size` 10 → 5 during the overlap (recommended over A14) | $0 | yes |

Still separately pending and **not** covered: the hosted Sprint 2 DB apply (`20261009090000` + `20261010090000…090400`).
