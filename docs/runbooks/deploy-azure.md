> **Superseded (25 Oct 2026):** Render is retired; the Render rollback steps here no longer apply. Current deploy: [docs/deploy.md](/docs/deploy.md) and [docs/HANDOVER.md](/docs/HANDOVER.md). Web uses the ACA edge URL as `VITE_API_BASE_URL`.

# Runbook: gateway API on Azure App Service (F1 Free, Linux)

Status (2026-10-09 ~17:00 IST): **live**. `main @ 3a81224` is deployed to
`https://medicore-hms-api.azurewebsites.net`. The web app on Vercel
(`https://medicore-hms-three.vercel.app`) points at it. The smoke test passed (see
`/workspace/deploy-evidence/smoke-azure.txt` on the box). This replaces Render
**for now**. The Render service `medicore-hms-api` (srv-db2htkbtqb8s73dfhlb0) was left
untouched, so it can be used for rollback.

> Secrets never appear in this file, the repo, chat, or logs. Wherever a secret is needed,
> it's read inside the shell with `$(cat /home/box/.secrets/...)` (files are chmod 600).
> Never use `set -x` while running these commands. Always pass `-o none` when setting app settings.

## 0. Prerequisites
```bash
export PATH=$HOME/.dotnet:$HOME/.local/bin:$PATH   # az CLI + .NET 10 SDK (dotnet-install.sh --channel 10.0)
az account show --query "{sub:name,id:id,user:user.name}" -o tsv
# Azure subscription 1  6f4c512a-8528-461a-962b-f4f8525223a3  kakanimohith566@gmail.com
```

## 1. Cost gate (run this before creating anything)
```bash
# F1 Linux is offered in Central India
az appservice list-locations --sku F1 --linux-workers-enabled --query "[].name" -o tsv | grep -x "Central India"
# Retail price for F1 in centralindia is 0
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Azure%20App%20Service'%20and%20armRegionName%20eq%20'centralindia'%20and%20skuName%20eq%20'F1'"
# Existing plans (free Linux plan limits)
az appservice plan list --query "[].{name:name,rg:resourceGroup,loc:location,sku:sku.name,linux:reserved}" -o table
```
Evidence from 2026-10-09:
- `Azure App Service Free Plan - Linux | F1 | F1 App | 0.0 USD / 1 Hour`. The Windows F1 meter is also 0.0 USD.
- The subscription already had an F1 Linux plan in Central India (`hospital-api-plan` in
  `hospital-api-rg`, belonging to another project, not touched). Creating a second F1 Linux plan in a **new** resource group
  still succeeded, so the free-plan limit is per resource group/webspace, not per region. If
  creation ever fails with a free-tier quota error, stop. Don't upgrade the SKU. Nearest free alternatives
  are South India / West India.
- Resources created: **only** the resource group, the plan, and the site. There is no ACR, Key Vault, App Insights, or storage
  (`az resource list -g rg-medicore-hms-dev` lists exactly `Microsoft.Web/serverFarms` and
  `Microsoft.Web/sites`).

## 2. Create resources
```bash
az group create -n rg-medicore-hms-dev -l centralindia --tags project=medicore-hms env=dev
az appservice plan create -g rg-medicore-hms-dev -n asp-medicore-hms-dev --sku F1 --is-linux -l centralindia
az appservice plan show -g rg-medicore-hms-dev -n asp-medicore-hms-dev --query "{sku:sku.name,tier:sku.tier}" -o tsv   # F1 Free
# Runtime: backend/Directory.Build.props targets net10.0, and DOTNETCORE|10.0 exists on Linux
az webapp list-runtimes --os linux -o tsv | grep -i dotnet
az webapp create -g rg-medicore-hms-dev -p asp-medicore-hms-dev -n medicore-hms-api \
  --runtime "DOTNETCORE:10.0" --https-only true
# (the CLI doesn't create Application Insights for `az webapp create`. Verify with az resource list)
```

## 3. App settings and config
```bash
A="-g rg-medicore-hms-dev -n medicore-hms-api"
az webapp config appsettings set $A -o none --settings \
  ASPNETCORE_ENVIRONMENT=Production \
  Auth__Supabase__ProjectUrl=https://gvgomzogbzbjhlcsimrx.supabase.co \
  OpenApi__Enabled=false \
  Cors__AllowedOrigins__0=https://medicore-hms-three.vercel.app \
  Cors__AllowedOrigins__1=https://medicore-hms-kakani-devs-projects.vercel.app \
  DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
  SCM_DO_BUILD_DURING_DEPLOYMENT=false
# Connection string is set in the shell only. "No Reset On Close=true" is REQUIRED (see section 6)
az webapp config appsettings set $A -o none --settings \
  ConnectionStrings__HmsDatabase="$(tr -d '\n' < /home/box/.secrets/medicore-hms-connstr | sed 's/;*$//');No Reset On Close=true" >/dev/null 2>&1
az webapp config set $A -o none --generic-configurations '{"healthCheckPath":"/health/live"}' \
  --ftps-state Disabled --min-tls-version 1.2 --startup-file "dotnet Hms.Gateway.dll"
az webapp log config $A -o none --application-logging filesystem --docker-container-logging filesystem --level warning
az webapp config appsettings list $A --query "[].name" -o tsv     # names only, never values
```
Port: the App Service .NET image sets `ASPNETCORE_URLS`/`PORT` to 8080, and the app doesn't override
it, so `WEBSITES_PORT` isn't needed.

## 4. Build and zip deploy (framework-dependent)
```bash
cd backend
dotnet publish gateway/Hms.Gateway/Hms.Gateway.csproj -c Release -o /tmp/hms-publish /p:UseAppHost=false
python3 -c "import shutil; shutil.make_archive('/tmp/hms-api','zip','/tmp/hms-publish')"
az webapp deploy -g rg-medicore-hms-dev -n medicore-hms-api --src-path /tmp/hms-api.zip --type zip --async false -o none
```

## 5. Verify
```bash
U=https://medicore-hms-api.azurewebsites.net
curl -s $U/health/live    # 200 {"status":"Healthy"...}
for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code} " $U/health/ready; done   # all 200
curl -s -o /dev/null -D - -X OPTIONS -H "Origin: https://medicore-hms-three.vercel.app" \
  -H "Access-Control-Request-Method: POST" $U/api/v1/me | grep -i access-control-allow-origin
# Smoke (web bundle -> Azure, live+ready, demo sign-in, /me, create + search SMOKE TEST Patient)
WEB_URL=https://medicore-hms-three.vercel.app API_URL=$U \
  PUBLISHABLE_KEY=sb_publishable_wKjEaH53IaWHuXif466l-A_WNlxxNTd scripts/smoke/deploy-smoke.sh
```
Logs: `az webapp log download -g rg-medicore-hms-dev -n medicore-hms-api --log-file /tmp/azlogs.zip`
(app stdout is in `LogFiles/*_default_docker.log`. It's Serilog JSON and has no connection strings.)

## 6. Gotcha: Supavisor transaction pooler (port 6543) needs `No Reset On Close=true`
Without it, `/health/ready` **alternated 200/503**. Every reused pooled connection hung on
`SELECT 1` until the 10 s command timeout ("Failed executing DbCommand (12,0xx ms) SELECT 1").
When Npgsql returns a connection to its pool, it resets the session (`DISCARD ALL`), and through
Supavisor in transaction mode that hangs. Npgsql's guidance for PgBouncer-style transaction pooling is
`Max Auto Prepare=0` (already set) **plus** `No Reset On Close=true`. This is safe here because the RLS context
uses transaction-local `set_config(..., true)`.
**Follow-up:** add `No Reset On Close=true` to `/home/box/.secrets/medicore-hms-connstr` (and to
the Render env var if Render is used again), or set it in code (`NpgsqlConnectionStringBuilder`). Otherwise
Render would show the same flapping.

## 7. Web (Vercel) points at Azure
- Project `medicore-hms` (prj_E7caJwNRXk3TMXBo4xnkcXmCI3hd): `VITE_API_BASE_URL` was changed from
  `https://medicore-hms-api-g1g4.onrender.com` to `https://medicore-hms-api.azurewebsites.net`
  (Production and Preview, plain). This was done with the Vercel MCP `edit_project_env` (env id bRNJQfk3oz8GvmNZ).
- Redeployed production from git `kakani-dev/hospital-management-system` ref `main`, sha
  `3a81224e…`, giving deployment `dpl_2PPJriHZ9EJjBdTrenrdgxAB7vix`. Aliases: medicore-hms-three, medicore-hms-kakani-devs-projects,
  medicore-hms-git-main-kakani-devs-projects. The live bundle `/assets/index-D9vg3rpJ.js` contains
  `medicore-hms-api.azurewebsites.net` and has 0 `onrender` references.
- Vite inlines `VITE_*` at build time, so after any env change you **must redeploy**.

## 8. F1 limits (known trade-offs)
- No Always On. The app unloads after ~20 min idle, and the next request has a cold start of ~30–60 s.
- 60 CPU-minutes/day and 1 GB RAM. When the quota is exceeded, the site stops (403) until the daily reset.
- No custom containers, deployment slots, autoscale, or custom-domain TLS. 1 instance only.
- The health-check path is set, but with one instance App Service can't replace an unhealthy instance.
- Shared outbound IPs (`az webapp show --query outboundIpAddresses`) are shared with other tenants, so
  a Supabase network allow-list on them is weak (same caveat as Render free, see Q6).

## 9. Rollback / teardown
```bash
# Point web back at Render: set VITE_API_BASE_URL=https://medicore-hms-api-g1g4.onrender.com
#   (Vercel dashboard -> medicore-hms -> Settings -> Environment Variables, or MCP edit_project_env
#    id bRNJQfk3oz8GvmNZ), then redeploy production from main. Render must have a working
#   ConnectionStrings__HmsDatabase (with No Reset On Close=true) first.
# Stop the API without deleting it:
az webapp stop -g rg-medicore-hms-dev -n medicore-hms-api
# Remove everything created by this runbook (needs Mohith's OK, it's irreversible):
az group delete -n rg-medicore-hms-dev --yes
```

## 10. Not done here / pending approvals
- Hosted migration `20261009090000` (N1, in main) is **not applied**. It needs Mohith's separate approval.
  The smoke flow (sign-in, /me, create + search patient) passed without it.
- SPA deep-link rewrites: `apps/web/vercel.json` (copy of `infra/vercel/vercel.json`; Vercel root directory = `apps/web`) is added on this branch. Deep links work once it is merged and production is redeployed.
