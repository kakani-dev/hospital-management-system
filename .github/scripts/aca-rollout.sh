#!/usr/bin/env bash
# Roll one or more MediCore container apps onto IMAGE_TAG and prove it through the edge.
#
# Multiple revision mode. The previous revision keeps 100% of the traffic until the new
# revision exists; traffic then moves to the new revision; /health/* on the public edge
# must pass. Any failure, or cancellation of this script, puts 100% of the traffic back
# on the previous revision and deactivates the new one.
#
# Never updates the legacy App Service medicore-hms-api. Never enables the outbox
# dispatcher (B1: it stays off on medicore-hms-api and on every service). No database
# migration. No registry password.
#
# ca-hms-identity, and only that app, receives SMTP_PASSWORD (secret smtp-password,
# Smtp__Password=secretref:smtp-password) and SUPABASE_SERVICE_ROLE_KEY (secret
# supabase-service-role, Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role),
# and Email__Dispatcher__Enabled=true. Identity is not rolled when either value is empty.
#
#   IMAGE_TAG=sha-<hex> .github/scripts/aca-rollout.sh identity patients
#   .github/scripts/aca-rollout.sh --rollback-only
#
# Required tools: az (already logged in), python3, curl.
set -euo pipefail

case $- in
  *x*) echo "refusing: xtrace would print SMTP_PASSWORD" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RG="${RESOURCE_GROUP:-rg-medicore-hms-dev}"
ACR_NAME="${ACR_NAME:-acrmedicorehmsdev}"
ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-${ACR_NAME}.azurecr.io}"
LEGACY_APP="medicore-hms-api"
STATE="${ROLLBACK_STATE:-${RUNNER_TEMP:-/tmp}/aca-rollback.tsv}"
IMAGE_TAG="${IMAGE_TAG:-}"
rolling=0

if [[ "$RG" != "rg-medicore-hms-dev" ]]; then
  echo "::error::refusing resource group $RG (this pipeline only deploys rg-medicore-hms-dev)" >&2
  exit 1
fi
if [[ "$ACR_NAME" != "acrmedicorehmsdev" ]]; then
  echo "::error::refusing registry $ACR_NAME" >&2
  exit 1
fi

if [[ -n "${SMTP_PASSWORD:-}" ]]; then
  echo "::add-mask::$SMTP_PASSWORD"
fi
if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "::add-mask::$SUPABASE_SERVICE_ROLE_KEY"
fi

die() { echo "::error::$*" >&2; exit 1; }

rollback_all() {
  [[ "$rolling" == 1 ]] && return 0
  rolling=1
  [[ -s "$STATE" ]] || return 0
  local line service app prev new rc=0
  local -a lines=()
  mapfile -t lines < <(tac "$STATE")
  set +e
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r service app prev new <<<"$line"
    [[ -n "$app" && -n "$new" && "$new" != "$prev" ]] || continue
    if [[ -z "$prev" ]]; then
      echo "::error::$app has no previous revision to restore; leaving $new in place" >&2
      rc=1
      continue
    fi
    echo "rolling $app back to $prev (deactivating $new)"
    az containerapp ingress traffic set -g "$RG" -n "$app" --revision-weight "${prev}=100" -o none || rc=1
    az containerapp revision deactivate -g "$RG" -n "$app" --revision "$new" -o none || rc=1
  done
  set -e
  return "$rc"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 ]]; then
    rollback_all || true
  fi
  exit "$status"
}

b1_legacy() {
  local value
  if ! value="$(az webapp config appsettings list -g "$RG" -n "$LEGACY_APP" \
      --query "[?name=='Outbox__Dispatcher__Enabled'].value | [0]" -o tsv)"; then
    die "B1 guard could not read $LEGACY_APP settings. The legacy App Service was not modified."
  fi
  case "$value" in
    true|True|TRUE|1)
      die "B1: $LEGACY_APP Outbox__Dispatcher__Enabled must stay false. Refusing to deploy."
      ;;
  esac
  echo "B1: $LEGACY_APP outbox dispatcher is off (setting ${value:-unset})"
}

preflight_app() {
  local service="$1" app="ca-hms-$1" identity outbox
  identity="$(az containerapp show -g "$RG" -n "$app" \
    --query "properties.configuration.registries[?server=='${ACR_LOGIN_SERVER}'].identity | [0]" -o tsv)"
  if [[ -z "$identity" || "$identity" == "None" ]]; then
    die "$app cannot pull from $ACR_LOGIN_SERVER with a managed identity. Run scripts/azure-oidc-setup.sh first."
  fi
  outbox="$(az containerapp show -g "$RG" -n "$app" \
    --query "properties.template.containers[0].env[?name=='Outbox__Dispatcher__Enabled'].value | [0]" -o tsv)"
  case "$outbox" in
    true|True|TRUE|1)
      die "B1: $app Outbox__Dispatcher__Enabled must stay false."
      ;;
  esac
  if ! az acr repository show -n "$ACR_NAME" --image "hms-${service}:${IMAGE_TAG}" -o none; then
    die "image hms-${service}:${IMAGE_TAG} is not in $ACR_NAME"
  fi
}

record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$STATE"
}

rollout_one() {
  local service="$1" app="ca-hms-$1" prev="" new="" suffix image rev_name
  image="${ACR_LOGIN_SERVER}/hms-${service}:${IMAGE_TAG}"
  suffix="$(python3 "$ROOT/.github/scripts/service_changes.py" suffix --app "$app" --tag "$IMAGE_TAG")"
  rev_name="${app}--${suffix}"

  az containerapp revision set-mode -g "$RG" -n "$app" --mode multiple -o none
  prev="$(az containerapp ingress traffic show -g "$RG" -n "$app" -o json | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if (r.get("weight") or 0) > 0]
print(rows[0].get("revisionName", "") if rows else "")
')"
  if [[ -z "$prev" ]]; then
    prev="$(az containerapp show -g "$RG" -n "$app" --query properties.latestRevisionName -o tsv)"
  fi

  if az containerapp revision show -g "$RG" -n "$app" --revision "$rev_name" -o none 2>/dev/null; then
    local existing
    existing="$(az containerapp revision show -g "$RG" -n "$app" --revision "$rev_name" \
      --query "properties.template.containers[0].image" -o tsv)"
    [[ "$existing" == "$image" ]] || die "$rev_name already exists with image $existing, not $image"
    new="$rev_name"
    echo "$app revision $new already has $image"
  else
    if [[ "$service" == "identity" ]]; then
      local err
      err="$(mktemp)"
      if ! az containerapp secret set -g "$RG" -n "$app" --secrets \
          "smtp-password=${SMTP_PASSWORD}" "supabase-service-role=${SUPABASE_SERVICE_ROLE_KEY}" \
          -o none >"$err" 2>&1; then
        rm -f "$err"
        die "failed to set identity mail secrets on $app (the values were not logged)"
      fi
      rm -f "$err"
      az containerapp update -g "$RG" -n "$app" --image "$image" --revision-suffix "$suffix" -o none \
        --set-env-vars \
        "Smtp__Password=secretref:smtp-password" \
        "Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role" \
        "Email__Dispatcher__Enabled=true"
    else
      az containerapp update -g "$RG" -n "$app" --image "$image" --revision-suffix "$suffix" -o none
    fi
    new="$(az containerapp show -g "$RG" -n "$app" --query properties.latestRevisionName -o tsv)"
  fi
  [[ -n "$new" ]] || die "$app did not produce a revision"
  record "$service" "$app" "$prev" "$new"

  if [[ "$new" != "$prev" ]]; then
    echo "shifting $app traffic to $new (previous $prev)"
    az containerapp ingress traffic set -g "$RG" -n "$app" --revision-weight "${new}=100" -o none
  fi

  local smoke_service="all"
  [[ "$service" != "edge" ]] && smoke_service="$service"
  if ! GATEWAY_URL="$GATEWAY_URL" SMOKE_MODE=health SMOKE_SERVICE="$smoke_service" \
      bash "$ROOT/scripts/smoke/post-deploy.sh"; then
    die "$app failed health checks through the edge"
  fi
}

main() {
  [[ -n "$IMAGE_TAG" ]] || die "IMAGE_TAG is required (sha-<hex>)"
  [[ "$IMAGE_TAG" =~ ^sha-[0-9a-f]{7,40}$ ]] || die "IMAGE_TAG must look like sha-<hex>"
  [[ "$#" -ge 1 ]] || die "name at least one service"

  local -a ordered=()
  local ordered_text
  ordered_text="$(python3 "$ROOT/.github/scripts/service_changes.py" order "$@")" || die "could not order services"
  mapfile -t ordered <<<"$ordered_text"
  [[ "${#ordered[@]}" -ge 1 && -n "${ordered[0]}" ]] || die "no services to roll out"

  local service
  for service in "${ordered[@]}"; do
    if [[ "$service" == "identity" ]]; then
      if [[ -z "${SMTP_PASSWORD:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
        die "Repository secret SMTP_PASSWORD or SUPABASE_SERVICE_ROLE_KEY is empty. Refusing to deploy identity without them."
      fi
    fi
  done

  : >"$STATE"
  b1_legacy
  local fqdn
  fqdn="$(az containerapp show -g "$RG" -n ca-hms-edge --query properties.configuration.ingress.fqdn -o tsv)"
  [[ -n "$fqdn" ]] || die "ca-hms-edge has no public fqdn"
  GATEWAY_URL="https://${fqdn}"

  for service in "${ordered[@]}"; do
    preflight_app "$service"
  done
  for service in "${ordered[@]}"; do
    rollout_one "$service"
  done
  if ! GATEWAY_URL="$GATEWAY_URL" SMOKE_MODE=full bash "$ROOT/scripts/smoke/post-deploy.sh"; then
    die "post-deploy smoke failed; restoring the previous revisions"
  fi
  echo "deployed $IMAGE_TAG to: ${ordered[*]}"
}

if [[ "${1:-}" == "--rollback-only" ]]; then
  rollback_all
  exit $?
fi

trap cleanup EXIT
main "$@"
