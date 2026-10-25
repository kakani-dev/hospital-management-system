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
# Does not change registry bindings. Patients keeps its existing ACR identity.
# Scheduling keeps its system-assigned identity. Both already have AcrPull.
# Does not write the identity app's hms-db secret (that value is hms_identity_login).
# Passes the current min/max replicas through. Identity must already be minReplicas 1.
#
# A service the live edge does not list yet is not proved through that edge. The edge
# would report it as missing until this same rollout publishes an edge revision that
# knows the cluster. The new container is proved on its own revision first (ingress
# target port 8080, HTTP probes on /health/live and /health/ready, same as the other
# services). The edge revision then sets every cluster address, including
# ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/,
# ReverseProxy__Clusters__inventory__Destinations__primary__Address=http://ca-hms-inventory/,
# ReverseProxy__Clusters__privacy__Destinations__primary__Address=http://ca-hms-privacy/,
# and only after that revision has traffic does /health/ready have to list the new
# service. A later deploy of a service the edge already lists is unchanged.
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
# "*" means the live edge's service list could not be read. Every service is then
# proved through the edge, which is the behaviour of a deploy that adds nothing.
EDGE_KNOWN="*"

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

# Azure rejects a write while another provisioning operation runs on the same app
# (ContainerAppOperationInProgress). Retry those writes with a wait; fail on anything else.
az_retry() {
  local attempt=1 max="${AZ_RETRY_ATTEMPTS:-20}" delay="${AZ_RETRY_DELAY_SECONDS:-15}" err rc
  err="$(mktemp)"
  while :; do
    if az "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    if grep -q 'ContainerAppOperationInProgress' "$err" && (( attempt < max )); then
      echo "   az $1 $2: operation in progress, retry ${attempt}/${max} in ${delay}s" >&2
      attempt=$((attempt + 1))
      sleep "$delay"
      continue
    fi
    cat "$err" >&2
    rm -f "$err"
    return "$rc"
  done
}

# After create/update: wait until the app is no longer provisioning and the expected
# revision is the latest one. Reading latestRevisionName earlier races the update.
wait_provisioned() {
  local app="$1" want="$2" state="" latest="" row
  local timeout="${PROVISION_TIMEOUT_SECONDS:-600}" interval="${PROVISION_INTERVAL_SECONDS:-5}"
  local deadline=$((SECONDS + timeout))
  while :; do
    row="$(az containerapp show -g "$RG" -n "$app" \
      --query "[properties.provisioningState, properties.latestRevisionName]" -o tsv 2>/dev/null | tr '\n' ' ' || true)"
    read -r state latest <<<"$row"
    if [[ "$state" == "Succeeded" && ( -z "$want" || "$latest" == "$want" ) ]]; then
      return 0
    fi
    if [[ "$state" == "Failed" || "$state" == "Canceled" ]]; then
      die "$app provisioning is $state (latest revision ${latest:-none}, expected ${want:-any})"
    fi
    if (( SECONDS >= deadline )); then
      die "$app did not finish provisioning within ${timeout}s (state ${state:-unknown}, latest ${latest:-none}, expected ${want:-any})"
    fi
    sleep "$interval"
  done
}

# Rollback must not exit on a timeout; it waits, then tries anyway.
wait_provisioned_soft() {
  ( wait_provisioned "$1" "" ) || echo "::warning::$1 still provisioning; attempting rollback step anyway" >&2
}

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
    wait_provisioned_soft "$app"
    az_retry containerapp ingress traffic set -g "$RG" -n "$app" --revision-weight "${prev}=100" -o none || rc=1
    wait_provisioned_soft "$app"
    if [[ "$(az containerapp revision show -g "$RG" -n "$app" --revision "$new" --query properties.active -o tsv 2>/dev/null)" == "false" ]]; then
      echo "   $new is already inactive"
    else
      az_retry containerapp revision deactivate -g "$RG" -n "$app" --revision "$new" -o none || rc=1
    fi
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

# Names the public edge currently returns from /health/ready. A brand-new cluster is
# absent here until the edge revision in this rollout is the one serving traffic.
edge_snapshot() {
  local body code names
  body="$(mktemp)"
  code="$(curl -sS --max-time "${CURL_MAX_TIME:-20}" -o "$body" -w '%{http_code}' "$GATEWAY_URL/health/ready" 2>/dev/null || true)"
  if [[ "$code" != "200" && "$code" != "503" ]]; then
    rm -f "$body"
    EDGE_KNOWN="*"
    echo "live edge readiness was HTTP ${code:-000}; checking every service through the edge"
    return 0
  fi
  if ! names="$(python3 - "$body" <<'PY'
import json, sys
try:
    document = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(1)
services = document.get("services")
if not isinstance(services, list):
    sys.exit(1)
print(" ".join(str(item.get("name")) for item in services if isinstance(item, dict) and item.get("name")))
PY
)"; then
    rm -f "$body"
    EDGE_KNOWN="*"
    echo "live edge readiness had no service list; checking every service through the edge"
    return 0
  fi
  rm -f "$body"
  EDGE_KNOWN="$names"
  echo "live edge reports: ${EDGE_KNOWN:-none}"
}

# A non-edge service the live edge does not list. The edge itself is never "fresh":
# its own update is what publishes the cluster addresses.
is_fresh() {
  [[ "$1" == "edge" ]] && return 1
  [[ "$EDGE_KNOWN" == "*" ]] && return 1
  [[ " $EDGE_KNOWN " == *" $1 "* ]] && return 1
  return 0
}

# Placeholder apps (the quickstart image) listen on 80 while ingress and the other
# services use 8080. One revision carries the image, the suffix, and the same HTTP
# probes deploy-aca.sh gives every service. Startup and liveness are /health/live
# (process only). Readiness is /health/ready.
ensure_listen() {
  local app="$1" image="$2" suffix="$3" id shown body
  az_retry containerapp ingress enable -g "$RG" -n "$app" --type internal --target-port 8080 \
    --transport auto --allow-insecure -o none
  id="$(az containerapp show -g "$RG" -n "$app" --query id -o tsv)"
  [[ -n "$id" ]] || die "$app has no resource id"
  shown="$(mktemp)"
  body="$(mktemp)"
  az containerapp show -g "$RG" -n "$app" -o json >"$shown"
  python3 - "$shown" "$body" "$image" "$suffix" "$SCALE_MIN" "$SCALE_MAX" <<'PY'
import json, sys
src, dest, image, suffix, scale_min, scale_max = sys.argv[1:]
app = json.load(open(src, encoding="utf-8"))
template = app["properties"]["template"]
container = template["containers"][0]
container["image"] = image
container["probes"] = [
    {"type": "Startup", "httpGet": {"path": "/health/live", "port": 8080, "scheme": "HTTP"},
     "initialDelaySeconds": 1, "periodSeconds": 2, "failureThreshold": 30, "timeoutSeconds": 5},
    {"type": "Liveness", "httpGet": {"path": "/health/live", "port": 8080, "scheme": "HTTP"},
     "periodSeconds": 30, "failureThreshold": 3, "timeoutSeconds": 5},
    {"type": "Readiness", "httpGet": {"path": "/health/ready", "port": 8080, "scheme": "HTTP"},
     "periodSeconds": 30, "failureThreshold": 3, "timeoutSeconds": 5},
]
scale = template.setdefault("scale", {})
scale["minReplicas"] = int(scale_min)
scale["maxReplicas"] = int(scale_max)
template["revisionSuffix"] = suffix
json.dump({"properties": {"template": template}}, open(dest, "w", encoding="utf-8"))
PY
  az_retry rest --method patch --url "https://management.azure.com${id}?api-version=2025-01-01" \
    --body @"$body" -o none
  rm -f "$shown" "$body"
}

wait_revision() {
  local app="$1" rev="$2" state="" interval="${SMOKE_INTERVAL_SECONDS:-5}"
  local timeout="${HEALTH_TIMEOUT_SECONDS:-150}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS <= deadline )); do
    state="$(az containerapp revision show -g "$RG" -n "$app" --revision "$rev" \
      --query properties.runningState -o tsv 2>/dev/null || true)"
    case "$state" in
      # Azure reports RunningAtMaxScale once replicas reach maxReplicas (1 here).
      Running|RunningAtMaxScale)
        echo "   ok $app revision $rev is ${state} (port 8080)"
        return 0
        ;;
      ActivationFailed|Failed)
        die "$app revision $rev is $state. Ingress target port is 8080 and probes are /health/live and /health/ready."
        ;;
    esac
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep "$interval"
  done
  die "$app revision $rev did not start within ${timeout}s (last state ${state:-unknown})"
}

# Read scale and pass it back on update so a new revision cannot fall back to 0.
# Identity is warm (minReplicas 1). Any other value means stop, not "fix" it.
read_scale() {
  local app="$1" service="$2"
  SCALE_MIN="$(az containerapp show -g "$RG" -n "$app" --query "properties.template.scale.minReplicas" -o tsv)"
  SCALE_MAX="$(az containerapp show -g "$RG" -n "$app" --query "properties.template.scale.maxReplicas" -o tsv)"
  if [[ "$service" == "identity" && "$SCALE_MIN" != "1" ]]; then
    die "$app minReplicas is '${SCALE_MIN:-unset}', expected 1. Refusing to change scale."
  fi
  [[ "$SCALE_MIN" =~ ^[0-9]+$ && "$SCALE_MAX" =~ ^[0-9]+$ ]] || die "$app scale could not be read"
}

secret_names() {
  az containerapp secret list -g "$RG" -n "$1" --query "[].name" -o tsv
}

# hms-db holds the identity database login. Never send a new value for it.
assert_hms_db() {
  local app="$1" names="$2" flat
  flat=" $(printf '%s' "$names" | tr '\n' ' ') "
  [[ "$flat" == *" hms-db "* ]] || die "$app is missing secret hms-db. Refusing to write secrets."
}

rollout_one() {
  local service="$1" app="ca-hms-$1" prev="" new="" suffix image rev_name
  image="${ACR_LOGIN_SERVER}/hms-${service}:${IMAGE_TAG}"
  # Image tag stays sha-<hex>. The revision suffix is short: s-<up to 12 hex>.
  # Azure rejects "{app}--{suffix}" when that whole name is longer than 54 characters.
  suffix="$(python3 "$ROOT/.github/scripts/service_changes.py" suffix --app "$app" --tag "$IMAGE_TAG")"
  rev_name="${app}--${suffix}"
  if ((${#rev_name} > 54)); then
    die "revision name ${rev_name} is ${#rev_name} characters; Azure allows at most 54"
  fi
  if [[ ! "$suffix" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ || "$suffix" == *"--"* ]]; then
    die "revision suffix ${suffix} must be lowercase letters, digits, and single hyphens"
  fi

  az_retry containerapp revision set-mode -g "$RG" -n "$app" --mode multiple -o none
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
    read_scale "$app" "$service"
    if [[ "$service" == "identity" ]]; then
      local err before after name
      before="$(secret_names "$app")"
      assert_hms_db "$app" "$before"
      err="$(mktemp)"
      # Only the two mail secrets. hms-db is not in this list, so its value is not replaced.
      if ! az_retry containerapp secret set -g "$RG" -n "$app" --secrets \
          "smtp-password=${SMTP_PASSWORD}" "supabase-service-role=${SUPABASE_SERVICE_ROLE_KEY}" \
          -o none >"$err" 2>&1; then
        rm -f "$err"
        die "failed to set identity mail secrets on $app (the values were not logged)"
      fi
      rm -f "$err"
      after="$(secret_names "$app")"
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ " $(printf '%s' "$after" | tr '\n' ' ') " == *" $name "* ]] || die "$app lost secret $name"
      done <<<"$before"
      assert_hms_db "$app" "$after"
      # --set-env-vars adds these three. It does not replace ConnectionStrings__HmsDatabase.
      az_retry containerapp update -g "$RG" -n "$app" --image "$image" --revision-suffix "$suffix" \
        --min-replicas "$SCALE_MIN" --max-replicas "$SCALE_MAX" -o none \
        --set-env-vars \
        "Smtp__Password=secretref:smtp-password" \
        "Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role" \
        "Email__Dispatcher__Enabled=true"
    elif [[ "$service" == "edge" ]]; then
      # appsettings.json keeps localhost for dev. Every edge revision stamps the
      # in-environment addresses, including a service that was not on the previous edge.
      az_retry containerapp update -g "$RG" -n "$app" --image "$image" --revision-suffix "$suffix" \
        --min-replicas "$SCALE_MIN" --max-replicas "$SCALE_MAX" -o none \
        --set-env-vars \
        "ReverseProxy__Clusters__identity__Destinations__primary__Address=http://ca-hms-identity/" \
        "ReverseProxy__Clusters__patients__Destinations__primary__Address=http://ca-hms-patients/" \
        "ReverseProxy__Clusters__scheduling__Destinations__primary__Address=http://ca-hms-scheduling/" \
        "ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/" \
        "ReverseProxy__Clusters__inventory__Destinations__primary__Address=http://ca-hms-inventory/" \
        "ReverseProxy__Clusters__privacy__Destinations__primary__Address=http://ca-hms-privacy/"
    elif is_fresh "$service"; then
      ensure_listen "$app" "$image" "$suffix"
    else
      az_retry containerapp update -g "$RG" -n "$app" --image "$image" --revision-suffix "$suffix" \
        --min-replicas "$SCALE_MIN" --max-replicas "$SCALE_MAX" -o none
    fi
    wait_provisioned "$app" "$rev_name"
    new="$(az containerapp show -g "$RG" -n "$app" --query properties.latestRevisionName -o tsv)"
  fi
  [[ -n "$new" ]] || die "$app did not produce a revision"
  # Rollback deactivates this recorded name. It must be the short suffix name,
  # not a name built from the full image tag.
  record "$service" "$app" "$prev" "$new"
  [[ "$new" == "$rev_name" ]] || die "$app latest revision is '${new}', expected ${rev_name}"

  if [[ "$new" != "$prev" ]]; then
    echo "shifting $app traffic to $new (previous $prev)"
    az_retry containerapp ingress traffic set -g "$RG" -n "$app" --revision-weight "${new}=100" -o none
    wait_provisioned "$app" ""
  fi

  # The live edge cannot see a cluster it was not built or configured with.
  # Prove the container itself, then let the edge revision in this rollout
  # (and the final smoke) require it on /health/ready.
  if is_fresh "$service"; then
    echo "$service is new to the live edge; not checking it through the edge until the edge revision is serving"
    wait_revision "$app" "$new"
    return 0
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
  edge_snapshot

  local -a fresh=()
  local has_edge=0
  for service in "${ordered[@]}"; do
    [[ "$service" == "edge" ]] && has_edge=1
    if is_fresh "$service"; then
      fresh+=("$service")
    fi
  done
  if [[ "${#fresh[@]}" -gt 0 && "$has_edge" != 1 ]]; then
    die "${fresh[*]} is not on the live edge yet. This rollout must include the edge so the cluster address is set before health is checked through it."
  fi
  if [[ "${#fresh[@]}" -gt 0 ]]; then
    echo "new to the live edge: ${fresh[*]}"
  fi

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
