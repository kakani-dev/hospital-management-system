# Runbook: database-per-service cutover and App Service shutdown

Status: **done** (2026-10-23). The App Service `medicore-hms-api` is stopped. Its project is
removed from the repository. Azure Container Apps serves `sha-c1d9516`. Vercel production uses
the edge. The steps below are the record of that cutover. Do not run them again.

The app and its plan were not deleted. Starting it again is `az webapp start` on that name, then
pointing `VITE_API_BASE_URL` back at the App Service and redeploying Vercel. That is a rollback,
not the current state.

Production web traffic is on the edge. The migration `20261022140000` is applied on the hosted
database. The App Service login `hms_api_login` was not changed; the stopped app is not serving.

Secrets never go in this file, the repo, chat, or logs. Do not run these commands under `set -x`.
Pass `-o none` when a command would print a setting value. Where a command prints a username,
that is the only field it may print.

Resource group `rg-medicore-hms-dev`. Subscription `6f4c512a-8528-461a-962b-f4f8525223a3`.
Registry `acrmedicorehmsdev`. Apps `ca-hms-edge`, `ca-hms-identity`, `ca-hms-patients`,
`ca-hms-scheduling`. Legacy app `medicore-hms-api`. Supabase project `gvgomzogbzbjhlcsimrx`.

## Why the order is one window

Images built before this change `SET ROLE authenticated` on every request. Images built from it
`SET ROLE hms_svc_<service>` (`Database:SessionRole` in the service `appsettings.json`).

- Apply `20261022140000` while an old image is serving and that image fails: `hms_svc_*` is no
  longer a member of `authenticated`, so `SET ROLE authenticated` is denied.
- Start a new image before the migration and that image fails: `hms_svc_*` does not yet have
  table grants, and it does not inherit them (`NOINHERIT`).

Do both in one sitting. The App Service keeps serving `hms_api_login` the whole time.
`Outbox__Dispatcher__Enabled` stays false on every app (B1). Do not grant `hms_dispatcher` or
`hms_mailer` to `hms_api`.

The GitHub deploy workflow (`.github/workflows/deploy-aca.yml`) never runs a migration and never
writes `ConnectionStrings__HmsDatabase`. It will roll the new images only after this commit is on
`main` and CI is green. If that deploy runs before step 2, the new revision fails health and the
workflow puts traffic back on the previous revision. That is safe. Then do step 2 and re-run the
deploy (or dispatch it).

## 0. Confirm the current logins

Group roles `hms_svc_identity`, `hms_svc_patients`, `hms_svc_scheduling` already exist
(migration `20261013090100`). Logins are out of band. On the hosted database, as the migration
role, list names only:

```sql
select rolname, rolcanlogin, rolinherit
  from pg_roles
 where rolname in (
   'hms_identity_login', 'hms_patients_login', 'hms_scheduling_login', 'hms_api_login',
   'hms_svc_identity', 'hms_svc_patients', 'hms_svc_scheduling', 'hms_api')
 order by rolname;
```

Expect the three `hms_*_login` roles, each `LOGIN` and `NOINHERIT`, and each granted its
`hms_svc_*` role. `hms_svc_*` is also a member of `anon` (public routes). Until step 2 it is
still a member of `authenticated`; after step 2 it is not. Create any missing login the same
way `hms_api_login` was created. `\password` sends only the SCRAM verifier:

```sql
create role hms_identity_login login noinherit nosuperuser nocreatedb nocreaterole
  noreplication nobypassrls connection limit 20;
create role hms_patients_login login noinherit nosuperuser nocreatedb nocreaterole
  noreplication nobypassrls connection limit 20;
create role hms_scheduling_login login noinherit nosuperuser nocreatedb nocreaterole
  noreplication nobypassrls connection limit 20;
```

Then, in psql: `\password hms_identity_login` (and the other two). Then the same guards as
`hms_api_login` (`statement_timeout` 8s, `lock_timeout` 3s, idle-in-transaction 15s). Do not set
`idle_session_timeout` (Supavisor holds idle server connections):

```sql
grant hms_svc_identity to hms_identity_login;
grant hms_svc_patients to hms_patients_login;
grant hms_svc_scheduling to hms_scheduling_login;
alter role hms_identity_login set statement_timeout = '8s';
alter role hms_identity_login set lock_timeout = '3s';
alter role hms_identity_login set idle_in_transaction_session_timeout = '15s';
alter role hms_patients_login set statement_timeout = '8s';
alter role hms_patients_login set lock_timeout = '3s';
alter role hms_patients_login set idle_in_transaction_session_timeout = '15s';
alter role hms_scheduling_login set statement_timeout = '8s';
alter role hms_scheduling_login set lock_timeout = '3s';
alter role hms_scheduling_login set idle_in_transaction_session_timeout = '15s';
```

Skip `CREATE ROLE` when the role already exists. Do not put these passwords in Container Apps
until the secret step below.

Confirm each Container App secret is that service's login, not `hms_api_login`. This prints the
`Username` field only:

```bash
for app in ca-hms-identity ca-hms-patients ca-hms-scheduling; do
  echo "== $app"
  az containerapp secret show -g rg-medicore-hms-dev -n "$app" --secret-name hms-db --query value -o tsv \
    | tr ';' '\n' | grep -E '^Username='
done
```

Expected: `Username=hms_identity_login`, `Username=hms_patients_login`, `Username=hms_scheduling_login`.
`docs/deploy.md` records that identity is already `hms_identity_login` and that the workflow will
not overwrite secret `hms-db`. If patients or scheduling still shows `hms_api_login`, replace that
app's `hms-db` secret with a connection string for its own login before step 2. Build it in the
shell from the existing Supavisor string (host, port 6543, database, `No Reset On Close=true`) and
the new user and password. Do not echo it. The new image cannot `SET ROLE hms_svc_*` from
`hms_api_login`.

Leave `medicore-hms-api` on `hms_api_login`.

## 1. Deploy the image that knows `Database:SessionRole`

Merge the change, wait until CI is green, and let `Deploy to Azure Container Apps` run (or
dispatch it from `main`). The new revision will fail its database health check until step 2, and
the workflow will send traffic back to the previous revision. That previous revision still uses
`authenticated` and still works. Do not set `Database__SessionRole` on the old revision.

Confirm `Outbox__Dispatcher__Enabled` is unset or false on `medicore-hms-api` and on all four
container apps. The rollout script refuses to continue if it is true. Do not set it to true.

## 2. Apply the ownership migration

On the hosted database, apply `supabase/migrations/20261022140000_platform_service_schema_ownership.sql`
once, as the role that owns the schemas. It sets `lock_timeout` 5s and `statement_timeout` 120s.
It:

- copies `authenticated`'s table, column, sequence, and function privileges onto `hms_svc_*`,
  schema by schema (`identity`, `patient`, `appointment`);
- adds `hms_svc_*` to that schema's RLS policies;
- grants `EXECUTE` on `auth.uid()`, the identity RLS helpers, and the `_v1` functions listed in
  `docs/architecture/monolith-inventory.md`;
- `REVOKE authenticated FROM hms_svc_identity, hms_svc_patients, hms_svc_scheduling`.

It does not revoke `anon`, does not change `hms_api` / `hms_api_login`, and does not contain
passwords. From this moment until step 3 finishes, the Container Apps revisions that are still on
the old image return errors. The App Service does not.

## 3. Put the new revisions in service

Re-run the deploy workflow, or update each app onto the image that contains this commit
(`acrmedicorehmsdev.azurecr.io/hms-<svc>:sha-<40 hex chars>`). The image's `appsettings.json`
sets `Database:SessionRole`. No separate env var is required. Do not let an update replace
`ConnectionStrings__HmsDatabase`.

Optional, only on the new revision, if you want the role visible beside the image:

```bash
az containerapp update -g rg-medicore-hms-dev -n ca-hms-identity \
  --set-env-vars Database__SessionRole=hms_svc_identity -o none
az containerapp update -g rg-medicore-hms-dev -n ca-hms-patients \
  --set-env-vars Database__SessionRole=hms_svc_patients -o none
az containerapp update -g rg-medicore-hms-dev -n ca-hms-scheduling \
  --set-env-vars Database__SessionRole=hms_svc_scheduling -o none
```

Identity stays at `minReplicas` 1. Do not change scale. Email secrets stay only on
`ca-hms-identity` (`smtp-password`, `supabase-service-role`). `Email__Dispatcher__Enabled` on
identity stays as the rollout left it. Scheduling's outbox dispatcher stays false.

Smoke, against the public edge FQDN (read it; do not guess):

```bash
EDGE=https://$(az containerapp show -g rg-medicore-hms-dev -n ca-hms-edge \
  --query properties.configuration.ingress.fqdn -o tsv)
curl -fsS "$EDGE/health/live"
for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code} " "$EDGE/health/ready"; done
echo
# 404 from the identity service (unknown token). A gateway "no such route" 404 is a failure.
curl -s -o /dev/null -w "%{http_code}\n" "$EDGE/api/v1/public/invites/$(printf '0%.0s' {1..64})"
curl -s -o /dev/null -w "%{http_code}\n" "$EDGE/api/v1/warmup"
```

Expect live 200, ready all 200, invite 404, warmup 200.

## 4. Point the web app at the edge

Separate approval. Vercel project `medicore-hms`. Change `VITE_API_BASE_URL` (Production, then
Preview) from `https://medicore-hms-api.azurewebsites.net` to the `EDGE` URL from step 3.
Redeploy production. Vite inlines the value at build time, so a redeploy is required. Rollback is
setting the variable back to the App Service URL and redeploying.

Do not change this from the repository. The web image and `apps/web/.env.example` do not carry
the production URL.

## 5. Stop the App Service

Separate approval, after step 4 has been smoked (sign-in, `/me`, a patient search) through the
edge. Stop. Do not delete the app or the plan.

```bash
az webapp stop -g rg-medicore-hms-dev -n medicore-hms-api
```

Confirm `Outbox__Dispatcher__Enabled` was never set to true. Confirm `hms_api` is still not a
member of `hms_dispatcher` or `hms_mailer`:

```sql
select pg_has_role('hms_api', 'hms_dispatcher', 'member') as api_dispatcher,
       pg_has_role('hms_api', 'hms_mailer', 'member') as api_mailer;
```

Both must be false.

To undo the stop: `az webapp start -g rg-medicore-hms-dev -n medicore-hms-api`, and point
`VITE_API_BASE_URL` back if step 4 already moved it. Do not drop the service roles or the
logins as part of that undo. The App Service does not need them.

## What this runbook does not do

- It does not delete `medicore-hms-api`, the App Service plan, or the resource group.
- It does not revoke `authenticated`'s own grants. PostgREST still uses that role. The App
  Service is stopped and is not serving.
- It does not split Postgres into physical databases. That decision is ADR 0002.
- It does not enable the scheduling outbox dispatcher.
