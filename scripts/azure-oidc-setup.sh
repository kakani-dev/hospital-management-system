#!/usr/bin/env bash
# One-time, idempotent Azure setup for GitHub Actions deploy of MediCore HMS.
# The CTO runs this once. After the three GitHub secrets exist, nothing else is manual.
#
#   AZURE_OIDC_SETUP_APPROVED=1 GH_SET_SECRETS=1 bash scripts/azure-oidc-setup.sh
#
# What it does (and will do again safely if you re-run it):
#   - App registration gh-medicore-hms-aca-deploy and its service principal. No client secret.
#   - Federated credential for GitHub Actions on the main branch only.
#     This repository was created on 2026-10-06, after GitHub's 2026-07-15
#     cutoff, so the subject is immutable:
#     repo:kakani-dev@249468300/hospital-management-system@1407449638:ref:refs/heads/main
#     The name-only subject does not match the token Actions sends.
#   - Azure Container Registry acrmedicorehmsdev (Basic, admin user disabled) in
#     rg-medicore-hms-dev, Central India.
#   - AcrPush and AcrDelete on that registry (push from Actions, delete of old sha- tags).
#   - Contributor on rg-medicore-hms-dev (container app rollouts and revision cleanup).
#   - For an app that already pulls from ACR, leave that registry identity alone.
#     Patients keeps its existing identity (AcrPull). Scheduling keeps its
#     system-assigned identity (AcrPull). Only an app with no ACR identity gets
#     a system identity, AcrPull, and a registry binding.
#
# It does not deploy an image, does not change medicore-hms-api, and does not enable the
# outbox dispatcher. Override defaults with SUB, TENANT, RG, LOC, ACR_NAME, APP_NAME, REPO.
#
# This script is not run from GitHub Actions.
set -euo pipefail

case $- in
  *x*) echo "refusing: xtrace would be unsafe around role and identity commands" >&2; exit 2 ;;
esac

if [[ "${AZURE_OIDC_SETUP_APPROVED:-}" != "1" ]]; then
  cat >&2 <<'EOF'
Refusing to run. This creates an Entra app, a container registry, and role assignments.
When you are ready:

  AZURE_OIDC_SETUP_APPROVED=1 GH_SET_SECRETS=1 bash scripts/azure-oidc-setup.sh
EOF
  exit 2
fi

SUB="${SUB:-6f4c512a-8528-461a-962b-f4f8525223a3}"
TENANT="${TENANT:-ab1a6103-6bda-47b9-8f1b-3bab684f84e3}"
RG="${RG:-rg-medicore-hms-dev}"
LOC="${LOC:-centralindia}"
ACR_NAME="${ACR_NAME:-acrmedicorehmsdev}"
APP_NAME="${APP_NAME:-gh-medicore-hms-aca-deploy}"
REPO="${REPO:-kakani-dev/hospital-management-system}"
# Numeric ids for kakani-dev/hospital-management-system. Used only when `gh` cannot
# read them. A different REPO must set both OWNER_ID and REPO_ID.
DEFAULT_OWNER_ID=249468300
DEFAULT_REPO_ID=1407449638
FED_NAME="github-actions-main"
ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
APPS=(ca-hms-edge ca-hms-identity ca-hms-patients ca-hms-scheduling ca-hms-billing ca-hms-inventory)

die() { echo "STOP: $*" >&2; exit 1; }
command -v az >/dev/null || die "az CLI not found"
[[ "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]] || die "ACR_NAME must be 5-50 lowercase letters or digits"
[[ "$REPO" == */* ]] || die "REPO must look like owner/name"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
[[ -n "$OWNER" && -n "$NAME" && "$OWNER" != "$REPO" && "$NAME" != "$REPO" ]] || die "REPO must look like owner/name"

# Actions on a repository created after 2026-07-15 sends owner id and repository id
# in `sub`. The workflow has no GitHub environment, so the claim also includes the
# branch. workflow_run (after CI) and workflow_dispatch from main both present it.
if [[ -z "${OWNER_ID:-}" || -z "${REPO_ID:-}" ]]; then
  meta=""
  if command -v gh >/dev/null; then
    meta="$(gh api "repos/${REPO}" --jq '[.owner.id, .id, .created_at] | @tsv' 2>/dev/null || true)"
  fi
  if [[ -n "$meta" ]]; then
    OWNER_ID="$(printf '%s' "$meta" | cut -f1)"
    REPO_ID="$(printf '%s' "$meta" | cut -f2)"
    created="$(printf '%s' "$meta" | cut -f3)"
    [[ "$created" == 20* ]] || die "could not read created_at for $REPO"
    # ISO-8601 sorts lexicographically. 2026-07-15 is GitHub's cutoff.
    if [[ "$created" < "2026-07-15" ]]; then
      die "$REPO was created $created, before the immutable subject cutoff. This script will not create a name-only credential."
    fi
  elif [[ "$REPO" == "kakani-dev/hospital-management-system" ]]; then
    OWNER_ID="$DEFAULT_OWNER_ID"
    REPO_ID="$DEFAULT_REPO_ID"
    echo "gh is not available; using known ids for $REPO (owner $OWNER_ID, repository $REPO_ID)"
  else
    die "set OWNER_ID and REPO_ID to the numeric ids of $REPO, or install gh"
  fi
fi
[[ "$OWNER_ID" =~ ^[0-9]+$ && "$REPO_ID" =~ ^[0-9]+$ ]] || die "OWNER_ID and REPO_ID must be numeric"
SUBJECT="repo:${OWNER}@${OWNER_ID}/${NAME}@${REPO_ID}:ref:refs/heads/main"

echo "subscription=$SUB tenant=$TENANT rg=$RG acr=$ACR_NAME subject=$SUBJECT"

az account set --subscription "$SUB"
[[ "$(az account show --query id -o tsv)" == "$SUB" ]] || die "az is not on subscription $SUB"
az group show -n "$RG" --query location -o tsv | grep -qx "$LOC" || die "resource group $RG is not in $LOC"

state="$(az provider show -n Microsoft.ContainerRegistry --query registrationState -o tsv)"
if [[ "$state" != "Registered" ]]; then
  echo "registering Microsoft.ContainerRegistry"
  az provider register -n Microsoft.ContainerRegistry --wait -o none
fi

# --- app registration + service principal (no password) ------------------------------------------
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[?displayName=='$APP_NAME'].appId | [0]" -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo "created app $APP_NAME $APP_ID"
else
  echo "app $APP_NAME already exists ($APP_ID)"
fi

if ! az ad sp show --id "$APP_ID" -o none 2>/dev/null; then
  az ad sp create --id "$APP_ID" -o none
fi
SP_OBJECT_ID=""
for _ in $(seq 1 12); do
  SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
  [[ -n "$SP_OBJECT_ID" ]] && break
  sleep 5
done
[[ -n "$SP_OBJECT_ID" ]] || die "service principal for $APP_ID did not appear"

existing_fed="$(az ad app federated-credential list --id "$APP_ID" \
  --query "[?subject=='$SUBJECT'].name | [0]" -o tsv)"
if [[ -z "$existing_fed" ]]; then
  fed="$(mktemp)"
  trap 'rm -f "$fed"' EXIT
  cat >"$fed" <<EOF
{
  "name": "$FED_NAME",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$SUBJECT",
  "description": "GitHub Actions deploy from the main branch",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create --id "$APP_ID" --parameters @"$fed" -o none
  rm -f "$fed"
  trap - EXIT
  echo "federated credential $FED_NAME created for $SUBJECT"
else
  echo "federated credential already present ($existing_fed)"
fi

# --- registry ------------------------------------------------------------------------------------
if az acr show -n "$ACR_NAME" -o none 2>/dev/null; then
  actual_rg="$(az acr show -n "$ACR_NAME" --query resourceGroup -o tsv)"
  [[ "$actual_rg" == "$RG" ]] || die "registry $ACR_NAME is in $actual_rg, not $RG"
  echo "registry $ACR_NAME already exists"
else
  az acr create -g "$RG" -n "$ACR_NAME" -l "$LOC" --sku Basic --admin-enabled false \
    --tags project=medicore-hms env=dev -o none
  echo "registry $ACR_NAME created (Basic, admin disabled)"
fi
az acr update -n "$ACR_NAME" --admin-enabled false -o none
ACR_ID="$(az acr show -n "$ACR_NAME" --query id -o tsv)"
RG_ID="$(az group show -n "$RG" --query id -o tsv)"

ensure_role() {
  local object_id="$1" role="$2" scope="$3"
  local found
  found="$(az role assignment list --assignee-object-id "$object_id" --role "$role" --scope "$scope" \
    --query "[0].id" -o tsv)"
  if [[ -n "$found" ]]; then
    echo "role $role already assigned on $scope"
    return 0
  fi
  az role assignment create \
    --assignee-object-id "$object_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" \
    --scope "$scope" \
    -o none
  echo "role $role assigned on $scope"
}

# AcrPush does not include manifest delete. Cleanup needs AcrDelete as well.
ensure_role "$SP_OBJECT_ID" "AcrPush" "$ACR_ID"
ensure_role "$SP_OBJECT_ID" "AcrDelete" "$ACR_ID"
ensure_role "$SP_OBJECT_ID" "Contributor" "$RG_ID"

# --- passwordless pull for the apps that already exist ------------------------------------------
missing=()
for app in "${APPS[@]}"; do
  if ! az containerapp show -g "$RG" -n "$app" -o none 2>/dev/null; then
    missing+=("$app")
    continue
  fi
  current="$(az containerapp show -g "$RG" -n "$app" \
    --query "properties.configuration.registries[?server=='${ACR_LOGIN_SERVER}'].identity | [0]" -o tsv)"
  if [[ -n "$current" && "$current" != "None" ]]; then
    echo "$app already pulls $ACR_LOGIN_SERVER with identity $current; leaving the registry binding alone"
    continue
  fi

  az containerapp identity assign -g "$RG" -n "$app" --system-assigned -o none
  pid=""
  for _ in $(seq 1 12); do
    pid="$(az containerapp identity show -g "$RG" -n "$app" --query principalId -o tsv 2>/dev/null || true)"
    [[ -n "$pid" ]] && break
    sleep 5
  done
  [[ -n "$pid" ]] || die "$app system identity has no principal id"
  ensure_role "$pid" "AcrPull" "$ACR_ID"
  az containerapp registry set -g "$RG" -n "$app" --server "$ACR_LOGIN_SERVER" --identity system -o none
  names="$(az containerapp secret list -g "$RG" -n "$app" --query "[].name" -o tsv | tr '\n' ' ')"
  [[ " $names " == *" hms-edge-key "* ]] || die "$app lost secret hms-edge-key after registry set (names: $names)"
  if [[ "$app" != "ca-hms-edge" ]]; then
    [[ " $names " == *" hms-db "* ]] || die "$app lost secret hms-db after registry set (names: $names)"
  fi
  echo "$app registry set to $ACR_LOGIN_SERVER (secrets still present: $names)"
done

echo
echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$TENANT"
echo "AZURE_SUBSCRIPTION_ID=$SUB"
echo "No client secret was created. Do not create one."
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "Container apps not found yet (re-run this script after they exist): ${missing[*]}"
fi
echo "Identity deploy also needs GitHub secrets SMTP_PASSWORD and SUPABASE_SERVICE_ROLE_KEY. They are stored only on ca-hms-identity. hms-db is not overwritten."
echo "The legacy app medicore-hms-api is unchanged. Keep Outbox__Dispatcher__Enabled off (B1)."

if [[ "${GH_SET_SECRETS:-}" == "1" ]]; then
  command -v gh >/dev/null || die "gh not found; export GH_SET_SECRETS=0 and set the three secrets yourself"
  gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
  gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT"
  gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB"
  echo "GitHub Actions secrets AZURE_CLIENT_ID, AZURE_TENANT_ID, and AZURE_SUBSCRIPTION_ID are set on $REPO."
else
  cat <<EOF

Set these GitHub Actions secrets on $REPO (or re-run with GH_SET_SECRETS=1):

  gh secret set AZURE_CLIENT_ID --repo $REPO --body "$APP_ID"
  gh secret set AZURE_TENANT_ID --repo $REPO --body "$TENANT"
  gh secret set AZURE_SUBSCRIPTION_ID --repo $REPO --body "$SUB"
EOF
fi
