# Start here: team handover

Full version (with Notion-only links): [Notion: Start here: team handover](https://app.notion.com/p/404ead9eb8a881a2b075c7963ecc3e93)

_Last verified: 25 Oct 2026, ~11 PM IST, main at `05b32c5`._

## What MediCore is
A multi-tenant Hospital Management System for Indian hospitals (tenants) and their branches: patients, scheduling and queue, OP billing with GST, pharmacy/inventory, DPDP privacy, earnings and CA dashboards. **Demo only, synthetic data only.**

## Stack and architecture
- **Web:** React 19 + TypeScript + Vite SPA in `apps/web`, deployed to Vercel (`medicore-hms-three.vercel.app`) by `deploy-web.yml`.
- **Backend:** .NET 10 minimal APIs. 7 Azure Container Apps in `rg-medicore-hms-dev` (Central India):
  - `ca-hms-edge` (public YARP edge, `https://ca-hms-edge.whiteisland-88abe7bd.centralindia.azurecontainerapps.io/api/v1/*`)
  - internal: `ca-hms-identity`, `ca-hms-patients`, `ca-hms-scheduling`, `ca-hms-billing`, `ca-hms-inventory`, `ca-hms-privacy`
- **Database:** Supabase Postgres, project `gvgomzogbzbjhlcsimrx`. Schema per service: `identity`, `patient`, `appointment`, `billing`, `inventory`, `privacy`, plus `audit` and `messaging` (outbox). RLS on memberships.
- **Auth:** Supabase Auth JWT, validated at the edge and in every service; edge adds `X-Hms-Edge-Key` and strips client `X-Hms-*` headers.
- Details: `docs/architecture/microservices.md`, ADRs in `docs/adr/`.

## Repo layout
`apps/web` SPA · `backend/edge` YARP edge · `backend/services/*` service hosts · `backend/modules/*` domain modules · `backend/platform` shared host plumbing · `backend/shared` kernel · `backend/tests` · `supabase/migrations` (schema source of truth) · `supabase/tests` SQL RLS tests · `tests/playwright` E2E · `scripts/` (incl. `scripts/demo`) · `infra/aca` · `.github/workflows`.

## Run locally and test
See `docs/local-development.md`. Short form:
```bash
npm ci
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres npm run sql:test   # throwaway DB + SQL tests
dotnet build backend/Hms.slnx
dotnet test backend/Hms.slnx --filter "Category!=Database"   # unit
dotnet test backend/Hms.slnx --filter "Category=Database"    # integration + RLS
npm run e2e     # Playwright (mock auth)
```

## Manual QA

199 test cases, P0 smoke checklist and bug triage guide: [docs/testing](testing/README.md). Notion: [QA Test Scenarios](https://app.notion.com/p/404ead9eb8a8819ab6b3e371d45b719e). File bugs with the issue templates (labels `bug`, `severity:*`, `qa`).

## CI/CD and go-live
- `ci.yml` is the required gate (`ci-ok`). `deploy-web.yml` deploys Vercel; `deploy-aca.yml` rolls the 7 ACA apps from main with rollback; `cleanup.yml` weekly.
- **Go-live procedure (one deploy at a time):**
  1. Back up (Supabase backup/dump of affected schemas).
  2. CI green (`ci-ok`) and review clean; PR has **Cases handled** + tests.
  3. Squash-merge to main.
  4. Apply new migrations to Supabase in order and rename the recorded version to match the file name.
  5. Deploy (workflows run on main); wait for all 7 apps on the new sha.
  6. Verify: edge health 200, web 200, protected API 401 without login, feature check in MediCore Demo Hospital.
  7. Update Notion (Release Notes, Sprint Tracker, Infrastructure) and close GitHub issues.

## House rules
- Synthetic data only. Demo data only in **MediCore Demo Hospital** (`77519cf6-1d9b-4954-8bc6-f29bbb734786`).
- Never trust a tenant ID from the client; resolve tenant/branch from the JWT and memberships server-side.
- No secrets in git, issues or docs; **the repo is public**.
- Migrations: `YYYYMMDDHHMMSS_<schema>_<what>.sql`, strictly in order, never edited after apply.
- No force-push to main; one deploy at a time.
- Every PR: small, has a **Cases handled** section and tests.
- Bugs are tracked only in GitHub issues.
- Build standard: design for scale, small tested PRs, monitoring, written decisions, security built in, automation, simplicity.

## Where secrets live (names only, never values)
- **ACA env (per app):** `ConnectionStrings__HmsDatabase`, `Edge__Key`, `Auth__Supabase__ProjectUrl`, `Outbox__Dispatcher__*`, `Cors__AllowedOrigins__*`.
- **GitHub Actions secrets:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (OIDC), `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `SUPABASE_SERVICE_ROLE_KEY`, `SMTP_PASSWORD`.
- **Supabase:** dashboard project settings (API keys, DB password, Auth hooks).
- **Vercel:** project env vars (`VITE_*` public config only).

## Current state (25 Oct 2026)
- Live: main `05b32c5`, release [v2026.10.25](https://github.com/kakani-dev/hospital-management-system/releases/tag/v2026.10.25). 73 migrations, head `20261025280100`. Outbox dispatcher ON.
- In progress: UPI/bank/card-terminal account mapping ([#63](https://github.com/kakani-dev/hospital-management-system/issues/63)); live end-to-end QA walkthrough.
- Open issues: https://github.com/kakani-dev/hospital-management-system/issues
- **Known risks:** free tiers (ACA scale-to-zero cold starts, Supabase limits); ACA secrets inline, no Key Vault (#68); leaked-password protection off (#69); 10 test gaps (#70–#79); Refund button status unconfirmed (#81).
- **Next priorities:** #63 UPI mapping, QA findings, test gaps #70/#71 (refund guards, OP billing E2E), day-end close beyond cash (#65), GL/Tally export (#62), appointment reminders (#59).
