# Deploy the API to Azure Container Apps

The web app stays on Vercel. Production deploys of the web app run from GitHub Actions after CI ([deploy the web app](runbooks/deploy-web.md)). This pipeline rolls the seven API containers.

| App | Image | Ingress |
|---|---|---|
| `ca-hms-edge` | `hms-edge` | public |
| `ca-hms-identity` | `hms-identity` | internal |
| `ca-hms-patients` | `hms-patients` | internal |
| `ca-hms-scheduling` | `hms-scheduling` | internal |
| `ca-hms-billing` | `hms-billing` | internal |
| `ca-hms-inventory` | `hms-inventory` | internal |
| `ca-hms-privacy` | `hms-privacy` | internal |

Resource group `rg-medicore-hms-dev`, Central India. Registry `acrmedicorehmsdev` (admin user disabled). Every app pulls `acrmedicorehmsdev.azurecr.io/hms-<svc>:sha-<full 40-character commit sha>`, not GHCR. Patients uses its existing identity with AcrPull. Scheduling uses its system-assigned identity with AcrPull. The deploy does not change those bindings.

`medicore-hms-api` (the App Service) is stopped. Production web traffic uses the edge. The pipeline does not read, start, deploy, or reconfigure that app. Before it updates any container it reads `Outbox__Dispatcher__Enabled` on all six container apps and refuses the deploy if any of them is true. On the current schema `hms_api` is not a member of `hms_dispatcher` (B1). This pipeline never runs a database migration.

ACR Basic is a paid SKU (about $0.17 per day). Container Apps stay on the consumption plan the apps were created with.

## What runs on its own

1. Push to `main`.
2. The `CI` workflow passes.
3. `Deploy to Azure Container Apps` starts. A newer push cancels a deploy that has not finished. An emergency dispatch waits, so it does not cut off a rollback.
4. Path filters pick the images to build. `backend/platform`, `backend/shared`, `Directory.Build.props`, `Directory.Packages.props`, `global.json`, a backend `packages.lock.json`, and `.dockerignore` build all seven. So do `.github/scripts/aca-rollout.sh`, `.github/scripts/service_changes.py`, `.github/scripts/aca-live-tags.sh`, and this deploy workflow. Otherwise only the service whose host or module changed is built. An app whose running image tag is not `sha-<this commit>` is included as well, so a container left on an older sha is rebuilt. Web, SQL, and the legacy gateway do not by themselves select an image. A blank `workflow_dispatch` uses that same plan. An explicit service or tag does not.
5. The image jobs run in parallel, push to ACR, and reuse Docker layer cache (`type=gha`).
6. Each changed app is switched to multiple revision mode. The new revision is created from the `sha-` tag. Traffic moves to it only after the revision exists. A service the live edge already lists is polled through the public edge (`/health/live`, and `/health/ready` for that service). A service the live edge does not list yet is not polled there: the old edge would report it missing until this rollout publishes the edge. That container is proved on its own revision first (ingress target port 8080, HTTP probes on `/health/live` and `/health/ready`). The edge revision in the same rollout sets every cluster address, including `ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/` and `ReverseProxy__Clusters__inventory__Destinations__primary__Address=http://ca-hms-inventory/` and `ReverseProxy__Clusters__privacy__Destinations__primary__Address=http://ca-hms-privacy/`. Those addresses are not left as a hand-edited revision. After that edge revision has traffic, `/health/ready` must list the new service. A deploy that adds a service and does not include the edge is refused.
7. A smoke check then calls `GET /api/v1/public/invites/<64 zeros>`. That route is anonymous and read-only. Success is **404 from the identity service** (unknown token). The gateway's own "no such route" 404 fails the deploy. Nothing is written.
8. If health or smoke fails, traffic goes back to the previous revision, the new revision is deactivated, and the job fails. Every app shifted in that run is restored, edge last.

`ca-hms-identity` is the only app that receives mail secrets. The deploy stores `SMTP_PASSWORD` as `smtp-password` and sets `Smtp__Password=secretref:smtp-password`. It stores `SUPABASE_SERVICE_ROLE_KEY` as `supabase-service-role` and sets `Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role`. It sets `Email__Dispatcher__Enabled=true` on that app. If either secret is empty, identity is not rolled. Patients, scheduling, and the edge are not given either secret. `Outbox__Dispatcher__Enabled` was off until 25 Oct 2026; it is now **ON** (PR #52 made the rollout work with it on).

The identity database login `hms_identity_login` lives in the existing secret `hms-db`. The workflow never writes that secret and does not replace `ConnectionStrings__HmsDatabase`. Identity runs with `minReplicas` 1. A rollout that does not already see 1 stops instead of changing the scale. Other apps keep the replica counts they already have.

`ca-hms-inventory` must exist in `rg-medicore-hms-dev` before a merge that adds it reaches `main`. Live tags fail closed when any app in the deploy order is missing, and the rollout does not create apps. Create it with internal ingress, target port 8080, and HTTP probes on `/health/live` and `/health/ready`, pulling `hms-inventory` with an ACR identity. Create the hosted login `hms_inventory_login` (`LOGIN NOINHERIT`) out of band with a generated password, then `GRANT hms_svc_inventory TO hms_inventory_login`. Set the ACA secret `hms-db` on `ca-hms-inventory` only to the Npgsql connection string for that login (pool, `No Reset On Close=true`, same shape as the other services). Set `ConnectionStrings__HmsDatabase=secretref:hms-db` and `Database__SessionRole=hms_svc_inventory`. The workflow never writes `hms-db`. There is no new GitHub Actions secret and no new Key Vault resource when the password stays in that per-app secret. The local throwaway password in `appsettings.json` is for local and CI databases only.

`ca-hms-privacy` has the same rule. Create it before this service is on `main`. Steps are in [the privacy container app runbook](runbooks/privacy-container-app.md). The rollout does not create the app. The edge revision sets `ReverseProxy__Clusters__privacy__Destinations__primary__Address=http://ca-hms-privacy/`; `appsettings.json` keeps `http://localhost:8106/` for local runs, the same way the other clusters do.

## One-time setup

Run this once, from a machine logged in to the subscription (`az login`) and, for the last line, authenticated to GitHub as someone who can write Actions secrets (`gh auth login`).

```bash
AZURE_OIDC_SETUP_APPROVED=1 GH_SET_SECRETS=1 bash scripts/azure-oidc-setup.sh
```

The script is idempotent. Re-running it does not create a second app, credential, registry, or role assignment. It never creates a client secret.

This repository was created on 2026-10-06, after GitHub's 15 July 2026 cutoff, so Actions sends an immutable subject. The federated credential must be exactly `repo:kakani-dev@249468300/hospital-management-system@1407449638:ref:refs/heads/main` (owner id `249468300`, repository id `1407449638`). The older name-only subject will not match the token, and `azure/login` will fail. The workflow has no GitHub environment, so the subject includes the branch. The post-CI deploy and an emergency dispatch from `main` both present that subject. The script reads the ids with `gh api` when `gh` is installed, and otherwise uses these known ids for this repository.

The same steps, if you need them without the script:

```bash
SUB=6f4c512a-8528-461a-962b-f4f8525223a3
TENANT=ab1a6103-6bda-47b9-8f1b-3bab684f84e3
RG=rg-medicore-hms-dev
LOC=centralindia
ACR_NAME=acrmedicorehmsdev
APP_NAME=gh-medicore-hms-aca-deploy
REPO=kakani-dev/hospital-management-system
# Immutable subject. Do not drop the @id segments.
SUBJECT="repo:kakani-dev@249468300/hospital-management-system@1407449638:ref:refs/heads/main"

az account set --subscription "$SUB"
# Register the registry provider only when it is not already registered.
state=$(az provider show -n Microsoft.ContainerRegistry --query registrationState -o tsv)
[[ "$state" == "Registered" ]] || az provider register -n Microsoft.ContainerRegistry --wait -o none

APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[?displayName=='$APP_NAME'].appId | [0]" -o tsv)
[[ -n "$APP_ID" ]] || APP_ID=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)
az ad sp show --id "$APP_ID" -o none 2>/dev/null || az ad sp create --id "$APP_ID" -o none
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Federated credential for the main branch only. No client secret.
az ad app federated-credential create --id "$APP_ID" --parameters "{\"name\":\"github-actions-main\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$SUBJECT\",\"audiences\":[\"api://AzureADTokenExchange\"]}"

az acr show -n "$ACR_NAME" -o none 2>/dev/null || \
  az acr create -g "$RG" -n "$ACR_NAME" -l "$LOC" --sku Basic --admin-enabled false \
    --tags project=medicore-hms env=dev -o none
az acr update -n "$ACR_NAME" --admin-enabled false -o none
ACR_ID=$(az acr show -n "$ACR_NAME" --query id -o tsv)
RG_ID=$(az group show -n "$RG" --query id -o tsv)

# AcrPush lets Actions push. AcrDelete lets the weekly cleanup remove old sha- tags
# (AcrPush cannot delete manifests). Contributor is limited to this resource group.
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role AcrPush --scope "$ACR_ID" -o none
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role AcrDelete --scope "$ACR_ID" -o none
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role Contributor --scope "$RG_ID" -o none

# Leave an app that already pulls from this registry on its current identity.
# Patients keeps its existing identity. Scheduling keeps system. Both have AcrPull.
for app in ca-hms-edge ca-hms-identity ca-hms-patients ca-hms-scheduling ca-hms-billing ca-hms-inventory ca-hms-privacy; do
  current=$(az containerapp show -g "$RG" -n "$app" \
    --query "properties.configuration.registries[?server=='${ACR_NAME}.azurecr.io'].identity | [0]" -o tsv)
  if [[ -n "$current" && "$current" != "None" ]]; then
    echo "$app already pulls ACR with identity $current; leaving the registry binding alone"
    continue
  fi
  az containerapp identity assign -g "$RG" -n "$app" --system-assigned -o none
  pid=$(az containerapp identity show -g "$RG" -n "$app" --query principalId -o tsv)
  az role assignment create --assignee-object-id "$pid" --assignee-principal-type ServicePrincipal \
    --role AcrPull --scope "$ACR_ID" -o none
  az containerapp registry set -g "$RG" -n "$app" --server "$ACR_NAME.azurecr.io" --identity system -o none
done

gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB"
```

Skip `GH_SET_SECRETS=1` if you want to set the secrets yourself. The script prints the three values either way.

If a container app does not exist yet, the script still creates the app registration, the registry, and the roles, then tells you to re-run it after the apps exist (`infra/aca/deploy-aca.sh` creates the apps). Re-running wires `AcrPull`.

## GitHub secrets

| Secret | Required | Value |
|---|---|---|
| `AZURE_CLIENT_ID` | yes | Application (client) id of `gh-medicore-hms-aca-deploy` |
| `AZURE_TENANT_ID` | yes | `ab1a6103-6bda-47b9-8f1b-3bab684f84e3` |
| `AZURE_SUBSCRIPTION_ID` | yes | `6f4c512a-8528-461a-962b-f4f8525223a3` |
| `SMTP_PASSWORD` | yes for identity | Gmail app password. Stored only on `ca-hms-identity` as `smtp-password`. Identity does not roll if this is empty. |
| `SUPABASE_SERVICE_ROLE_KEY` | yes for identity | GoTrue service-role key. Stored only on `ca-hms-identity` as `supabase-service-role`. |
| `HMS_EDGE_KEY` | when `ACA_SECRETS_SOURCE=github` | Edge-to-service key. Same value on all seven apps as `hms-edge-key` (`Edge__Key`). |
| `HMS_DB_IDENTITY` | when `ACA_SECRETS_SOURCE=github` | Identity database connection string (`hms_identity_login`). `hms-db` on `ca-hms-identity`. |
| `HMS_DB_PATIENTS` | when `ACA_SECRETS_SOURCE=github` | `hms-db` on `ca-hms-patients`. |
| `HMS_DB_SCHEDULING` | when `ACA_SECRETS_SOURCE=github` | `hms-db` on `ca-hms-scheduling`. |
| `HMS_DB_BILLING` | when `ACA_SECRETS_SOURCE=github` | `hms-db` on `ca-hms-billing`. |
| `HMS_DB_INVENTORY` | when `ACA_SECRETS_SOURCE=github` | `hms-db` on `ca-hms-inventory`. |
| `HMS_DB_PRIVACY` | when `ACA_SECRETS_SOURCE=github` | `hms-db` on `ca-hms-privacy`. |
| `HMS_EDGE_KEY_PREVIOUS` | optional, only during an edge-key rotation | Previous edge key, accepted by the six services as `hms-edge-key-previous` (`Edge__PreviousKey`). Skipped while empty or unset. |

### App secrets from GitHub (issue #68)

`.github/aca-secrets.tsv` is the single map from Container Apps secret to GitHub secret to env var. The repository variable `ACA_SECRETS_SOURCE` picks the mode:

- unset or `legacy`: today's behaviour. Only the identity mail pair is written; `hms-db` and `hms-edge-key` stay as they are on each app.
- `github`: every row is applied. Before any write the deploy fails if a needed secret is empty (names only in the log). Each value is masked, compared with the live value by hash, and written only if different, then referenced as `Name=secretref:<secret>`, never as a plain env value. A failed rollout restores the previous values it changed. Changing `HMS_EDGE_KEY` is refused unless all seven apps roll in the same run; use the emergency hatch with the current tag and a blank service.

Container Apps secrets are app-level, not per revision, so a revision rollback alone does not bring an old value back. The in-run restore covers that; a cancelled job restores revisions only.

- mode `optional` rows (only `HMS_EDGE_KEY_PREVIOUS`) apply in `github` mode only while the GitHub secret is non-empty.

Rotating any of these without downtime: [runbooks/credential-rotation.md](runbooks/credential-rotation.md) (blue/green DB logins, dual edge key).

`bash .github/scripts/aca-secrets.sh names github` lists the names. CI runs `.github/scripts/aca-secrets.test.sh` against a fake `az`.

Do not create a client secret. The workflow asks Entra for a short-lived token with the federated credential above. Pulls use the identity already on each app (`AcrPull`), not a registry password. Patients keeps its existing identity. Scheduling keeps its system-assigned identity.

## Emergency hatch

Normal deploys do not use this. From `main`:

```bash
# Roll patients back to an image that is already in the registry. Nothing is built.
gh workflow run "Deploy to Azure Container Apps" --ref main \
  -f service=patients -f tag=sha-0123456789ab

# Rebuild and roll only the edge from the current main commit.
gh workflow run "Deploy to Azure Container Apps" --ref main -f service=edge
```

The same health check, smoke test, and automatic rollback apply. `service` is one of `identity`, `patients`, `scheduling`, `billing`, `inventory`, `privacy`, `edge`. A service the live edge does not list yet is refused on its own; roll the edge in the same deploy.

## Cleanup

`.github/workflows/cleanup.yml` runs every Monday at 03:17 UTC and deletes for real. It also has a manual run:

```bash
# Preview only.
gh workflow run "Cleanup old artifacts, caches, and revisions" -f dry_run=true -f max_age_days=7

# Real run (same as the weekly schedule).
gh workflow run "Cleanup old artifacts, caches, and revisions" -f dry_run=false
```

- Artifacts older than 7 days, and caches not used for 7 days (`max_age_days` changes only this part).
- In `acrmedicorehmsdev`, the 10 newest `sha-` tags of each `hms-*` repository, plus any tag that is on a running or traffic-bearing revision. Other tags are not deleted. If the deployed image cannot be read, nothing is deleted.
- Inactive Container Apps revisions beyond the newest 3 are deactivated. A revision with traffic, replicas, or that is still starting is kept.

Artifact uploads in CI set `retention-days: 7`.
