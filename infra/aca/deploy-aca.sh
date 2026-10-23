#!/usr/bin/env bash
# =====================================================================================================
# MediCore HMS -> Azure Container Apps (Consumption, Central India). IDEMPOTENT. PREPARED, NOT RUN.
#
#   APPROVED=1 IMAGE_SHA=<40-hex main sha> [LOGS=la|none] bash infra/aca/deploy-aca.sh
#
# Creates/updates ONLY in resource group rg-medicore-hms-dev:
#   - (LOGS=la, default) Log Analytics workspace log-medicore-hms-dev, PerGB2018, 30-day retention,
#     daily cap 0.15 GB (stays inside the 5 GB/month free ingestion per billing account)
#   - Container Apps environment cae-medicore-hms-dev (Consumption-only, no workload profiles)
#   - ca-hms-edge (external ingress) + ca-hms-identity / ca-hms-patients / ca-hms-scheduling / ca-hms-billing (internal)
#     0.25 vCPU / 0.5 GiB, min 0 / max 1 replicas, port 8080, startup/liveness/readiness probes,
#     PRIVATE GHCR images ghcr.io/kakani-dev/hms-<svc>:sha-<IMAGE_SHA>, pulled with a registry
#     credential (kakani-dev token with read:packages, stored as a Container Apps secret)
#   - secrets: hms-db (services) from /home/box/.secrets/medicore-hms-connstr (pool forced to 5),
#              hms-edge-key (all 4) from /home/box/.secrets/medicore-hms-edge-key (generated if missing)
# It never registers resource providers, never creates ACR / Key Vault / App Insights / dedicated
# profiles, never touches Render, Vercel, the F1 app or the Supabase database.
# Secrets are read inside this shell only; nothing secret is echoed, and `set -x` is refused.
# Docs: docs/architecture/microservices-ci-and-aca-plan.md ("Deploy day").
# =====================================================================================================
set -euo pipefail

if [[ "${APPROVED:-}" != "1" ]]; then
  cat >&2 <<'BANNER'
#####################################################################################
#  REFUSING TO RUN: APPROVED=1 is not set.                                          #
#  This script creates billable-capable Azure resources (Container Apps environment, #
#  5 container apps, optionally a Log Analytics workspace) in rg-medicore-hms-dev.   #
#  The subscription is Pay-As-You-Go with NO spending limit.                         #
#  Run it only after Mohith has approved the items in the plan's "Deploy day"        #
#  checklist, then:  APPROVED=1 IMAGE_SHA=<sha> bash infra/aca/deploy-aca.sh         #
#####################################################################################
BANNER
  exit 2
fi
case "$-" in *x*) echo "refusing: xtrace (set -x) would print secrets" >&2; exit 2 ;; esac

export PATH="$HOME/.local/bin:$PATH"
SUB="${SUB:-6f4c512a-8528-461a-962b-f4f8525223a3}"
RG="${RG:-rg-medicore-hms-dev}"
LOC="${LOC:-centralindia}"
ENV_NAME="${ENV_NAME:-cae-medicore-hms-dev}"
LAW_NAME="${LAW_NAME:-log-medicore-hms-dev}"
LOGS="${LOGS:-la}"                    # la = Log Analytics with daily cap (default), none = no log storage
LA_DAILY_CAP_GB="${LA_DAILY_CAP_GB:-0.15}"
LA_RETENTION_DAYS="${LA_RETENTION_DAYS:-30}"   # 31 days of analytics retention are included in ingestion
IMAGE_SHA="${IMAGE_SHA:-}"
REGISTRY="${REGISTRY:-ghcr.io/kakani-dev}"
POOL_SIZE="${POOL_SIZE:-5}"           # per service: 3 x 5 = 15 client connections
SUPABASE_URL="${SUPABASE_URL:-https://gvgomzogbzbjhlcsimrx.supabase.co}"
CORS_0="${CORS_0:-https://medicore-hms-three.vercel.app}"
CORS_1="${CORS_1:-https://medicore-hms-kakani-devs-projects.vercel.app}"
CONNSTR_FILE="${CONNSTR_FILE:-/home/box/.secrets/medicore-hms-connstr}"
EDGE_KEY_FILE="${EDGE_KEY_FILE:-/home/box/.secrets/medicore-hms-edge-key}"
# inventory is not in this loop. The script writes one shared hms-db secret, and the
# inventory login must not receive the identity connection string. Create ca-hms-inventory
# out of band and set its own hms-db secret before the first rollout.
SERVICES=(identity patients scheduling billing)
TAGS=(project=medicore-hms env=dev cost=free-grant)

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'STOP: %s\n' "$*" >&2; exit 1; }
quiet() { "$@" -o none >/dev/null 2>&1; }   # for commands that carry secrets: discard ALL output

[[ "$IMAGE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "IMAGE_SHA must be a full 40-hex commit sha (got '${IMAGE_SHA}')"
[[ "$LOGS" == "la" || "$LOGS" == "none" ]] || die "LOGS must be 'la' or 'none'"
command -v az >/dev/null || die "az CLI not found"
command -v python3 >/dev/null || die "python3 not found"

# ---------------------------------------------------------------------------------------------------
log "0. account + cost gate (read-only)"
az account set -s "$SUB"
[[ "$(az account show --query id -o tsv)" == "$SUB" ]] || die "wrong subscription"
az group show -n "$RG" --query location -o tsv | grep -qx "$LOC" || die "resource group $RG not in $LOC"

prices() { curl -fsS "https://prices.azure.com/api/retail/prices?\$filter=$1"; }
prices "serviceName%20eq%20'Azure%20Container%20Apps'%20and%20armRegionName%20eq%20'${LOC}'" | python3 -c '
import json, sys
items = {(i["skuName"], i["meterName"]): i["retailPrice"] for i in json.load(sys.stdin)["Items"] if i["type"] == "Consumption"}
need = {("Standard", "Standard vCPU Active Usage"): 0.000024, ("Standard", "Standard Memory Active Usage"): 0.000003,
        ("Standard", "Standard vCPU Idle Usage"): 0.000003, ("Standard", "Standard Requests"): 0.4}
for k, v in need.items():
    got = items.get(k)
    print(f"   price {k[1]:32s} {got}")
    if got is None or got > v * 1.5:
        sys.exit(f"STOP: unexpected Container Apps price for {k[1]}: {got} (plan assumed {v})")
' || die "Container Apps price check failed"
if [[ "$LOGS" == "la" ]]; then
  prices "serviceName%20eq%20'Log%20Analytics'%20and%20armRegionName%20eq%20'${LOC}'%20and%20meterName%20eq%20'Analytics%20Logs%20Data%20Ingestion'" | python3 -c '
import json, sys
tiers = sorted((i["tierMinimumUnits"], i["retailPrice"]) for i in json.load(sys.stdin)["Items"] if i["type"] == "Consumption")
print("   price Log Analytics ingestion tiers (GB, USD/GB):", tiers)
if not tiers or tiers[0] != (0.0, 0.0):
    sys.exit("STOP: Log Analytics first tier is not free")
' || die "Log Analytics price check failed"
  python3 -c "import sys; c=float('$LA_DAILY_CAP_GB'); sys.exit(0 if c*31 <= 4.9 else 'STOP: daily cap x 31 days exceeds the 5 GB free tier')" \
    || die "daily cap too high"
fi

# ---------------------------------------------------------------------------------------------------
log "1. provider + quota check (no registration is done here)"
state=$(az provider show -n Microsoft.App --query registrationState -o tsv)
[[ "$state" == "Registered" ]] || die "Microsoft.App is '$state'. Registering it is approval item A1 (az provider register -n Microsoft.App --wait)."
if [[ "$LOGS" == "la" ]]; then
  state=$(az provider show -n Microsoft.OperationalInsights --query registrationState -o tsv)
  [[ "$state" == "Registered" ]] || die "Microsoft.OperationalInsights is '$state' (needed for LOGS=la; approval item A1b). Or rerun with LOGS=none."
fi
read -r q_cur q_lim < <(az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.App/locations/$LOC/usages?api-version=2024-03-01" \
  --query "value[?name.value=='ManagedEnvironmentCount'] | [0].join(' ', [to_string(currentValue), to_string(limit)])" -o tsv)
log "   ManagedEnvironmentCount $q_cur / $q_lim"
env_exists=false
az containerapp env show -g "$RG" -n "$ENV_NAME" -o none >/dev/null 2>&1 && env_exists=true
if [[ "$env_exists" == false ]]; then
  [[ "${q_lim:-0}" -ge 1 && "${q_cur:-0}" -lt "${q_lim:-0}" ]] || die "no Container Apps environment quota in $LOC ($q_cur/$q_lim). Request quota (free) before continuing."
fi

# ---------------------------------------------------------------------------------------------------
log "2. local secrets"
[[ -r "$CONNSTR_FILE" ]] || die "$CONNSTR_FILE missing"
grep -qiE '(^|;) *No Reset On Close *= *true *(;|$)' "$CONNSTR_FILE" || die "connection string lacks 'No Reset On Close=true'"
grep -qE ':6543|Port=6543' "$CONNSTR_FILE" || log "   WARNING: connection string is not on the Supavisor transaction pooler port 6543"
if [[ ! -s "$EDGE_KEY_FILE" ]]; then
  ( umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(48), end="")' > "$EDGE_KEY_FILE" )
  log "   generated new edge key at $EDGE_KEY_FILE (64 url-safe chars = 48 random bytes; not printed)"
fi
chmod 600 "$EDGE_KEY_FILE" "$CONNSTR_FILE"
[[ "$(wc -c < "$EDGE_KEY_FILE")" -ge 43 ]] || die "edge key shorter than 32 bytes"
# Connection string for the services: pool forced to $POOL_SIZE (replaces any Maximum Pool Size). Kept in a variable only.
svc_connstr() {
  tr -d '\n' < "$CONNSTR_FILE" | python3 -c '
import sys
pool = sys.argv[1]
parts = [p for p in sys.stdin.read().split(";") if p.strip()]
parts = [p for p in parts if p.split("=", 1)[0].strip().lower().replace(" ", "") not in ("maximumpoolsize", "maxpoolsize")]
parts.append("Maximum Pool Size=" + pool)
print(";".join(parts), end="")' "$POOL_SIZE"
}

# ---------------------------------------------------------------------------------------------------
GHCR_USER="${GHCR_USER:-kakani-dev}"
ghcr_token() { if [[ -n "${GHCR_TOKEN_FILE:-}" ]]; then cat "$GHCR_TOKEN_FILE"; else /usr/local/bin/gh auth token -u "$GHCR_USER"; fi; }
log "3. images (private GHCR pull check, sha-$IMAGE_SHA)"
for app in edge "${SERVICES[@]}"; do
  repo="${REGISTRY#ghcr.io/}/hms-$app"
  tok=$(curl -fsS -u "kakani-dev:$(ghcr_token)" "https://ghcr.io/token?scope=repository:${repo}:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))') \
    || die "GHCR token failed for $repo (package missing or token lacks read:packages)"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/${repo}/manifests/sha-${IMAGE_SHA}")
  [[ "$code" == 200 ]] || die "ghcr.io/$repo:sha-$IMAGE_SHA not pullable with the registry credential (HTTP $code)"
  log "   ok hms-$app"
done

# ---------------------------------------------------------------------------------------------------
LAW_ID=""
if [[ "$LOGS" == "la" ]]; then
  log "4a. Log Analytics workspace $LAW_NAME (PerGB2018, cap ${LA_DAILY_CAP_GB} GB/day, ${LA_RETENTION_DAYS} d)"
  if ! az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" -o none >/dev/null 2>&1; then
    az monitor log-analytics workspace create -g "$RG" -n "$LAW_NAME" -l "$LOC" --sku PerGB2018 \
      --retention-time "$LA_RETENTION_DAYS" --quota "$LA_DAILY_CAP_GB" --tags "${TAGS[@]}" -o none
  else
    az monitor log-analytics workspace update -g "$RG" -n "$LAW_NAME" \
      --retention-time "$LA_RETENTION_DAYS" --quota "$LA_DAILY_CAP_GB" -o none
  fi
  cap=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" --query workspaceCapping.dailyQuotaGb -o tsv)
  sku=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" --query sku.name -o tsv)
  log "   workspace sku=$sku dailyQuotaGb=$cap"
  [[ "$sku" == "PerGB2018" ]] || die "workspace sku $sku"
  python3 -c "import sys; sys.exit(0 if abs(float('$cap')-float('$LA_DAILY_CAP_GB'))<1e-6 else 1)" || die "daily cap not applied"
  LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" --query customerId -o tsv)
fi

log "4b. Container Apps environment $ENV_NAME (Consumption-only, logs=$LOGS)"
if [[ "$env_exists" == false ]]; then
  if [[ "$LOGS" == "la" ]]; then
    quiet az containerapp env create -g "$RG" -n "$ENV_NAME" -l "$LOC" --enable-workload-profiles false \
      --logs-destination log-analytics --logs-workspace-id "$LAW_ID" \
      --logs-workspace-key "$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW_NAME" --query primarySharedKey -o tsv)" \
      --tags "${TAGS[@]}" || die "environment create failed (rerun without output suppression is NOT allowed: it would print the workspace key; check the activity log)"
  else
    az containerapp env create -g "$RG" -n "$ENV_NAME" -l "$LOC" --enable-workload-profiles false \
      --logs-destination none --tags "${TAGS[@]}" -o none
  fi
else
  cur=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query "properties.appLogsConfiguration.destination" -o tsv)
  want=$([[ "$LOGS" == "la" ]] && echo log-analytics || echo "")
  if [[ "$cur" != "$want" ]]; then
    log "   switching logs destination '$cur' -> '${want:-none}'"
    if [[ "$LOGS" == "la" ]]; then
      quiet az containerapp env update -g "$RG" -n "$ENV_NAME" --logs-destination log-analytics --logs-workspace-id "$LAW_ID" \
        --logs-workspace-key "$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW_NAME" --query primarySharedKey -o tsv)" \
        || die "environment logs update failed"
    else
      az containerapp env update -g "$RG" -n "$ENV_NAME" --logs-destination none -o none
    fi
  fi
fi
wp=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query "length((properties.workloadProfiles || \`[]\`)[?workloadProfileType!='Consumption'])" -o tsv)
[[ "$wp" == "0" ]] || die "environment has workload profiles ($wp); dedicated profiles cost money. Investigate before continuing."
DOMAIN=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query properties.defaultDomain -o tsv)
log "   ok, default domain $DOMAIN"

# ---------------------------------------------------------------------------------------------------
# Template (container + scale) as JSON, NO secret values: env vars only reference secrets by name.
template_json() { # app image ready_path env...(NAME=VALUE or NAME=secretref:x)
  python3 - "$@" <<'PY'
import json, sys
app, image, ready, *envs = sys.argv[1:]
env = []
for e in envs:
    k, v = e.split("=", 1)
    env.append({"name": k, "secretRef": v[len("secretref:"):]} if v.startswith("secretref:") else {"name": k, "value": v})
probe = lambda t, path, period, fail, extra=None: {"type": t, "httpGet": {"path": path, "port": 8080, "scheme": "HTTP"},
                                                 "periodSeconds": period, "failureThreshold": fail, "timeoutSeconds": 5, **(extra or {})}
print(json.dumps({"properties": {"template": {
    "containers": [{
        "name": app, "image": image, "env": env,
        "resources": {"cpu": 0.25, "memory": "0.5Gi"},
        "probes": [probe("Startup", "/health/live", 2, 30, {"initialDelaySeconds": 1}),
                   probe("Liveness", "/health/live", 30, 3),
                   probe("Readiness", ready, 30, 3)]}],
    "scale": {"minReplicas": 0, "maxReplicas": 1,
              "rules": [{"name": "http", "http": {"metadata": {"concurrentRequests": "20"}}}]}}}}))
PY
}

deploy_app() { # app ingress(external|internal) ready_path secrets_csv env...
  local app="$1" ingress="$2" ready="$3" secrets_csv="$4"; shift 4
  local name="ca-hms-$app" image="$REGISTRY/hms-$app:sha-$IMAGE_SHA"
  local secret_args=() s
  IFS=',' read -r -a wanted <<<"$secrets_csv"
  for s in "${wanted[@]}"; do
    case "$s" in
      hms-db)       secret_args+=("hms-db=$(svc_connstr)") ;;
      hms-edge-key) secret_args+=("hms-edge-key=$(cat "$EDGE_KEY_FILE")") ;;
    esac
  done
  if ! az containerapp show -g "$RG" -n "$name" -o none >/dev/null 2>&1; then
    log "   create $name ($ingress)"
    local extra=()
    [[ "$ingress" == internal ]] && extra=(--allow-insecure)   # http://ca-hms-<svc> inside the environment; never leaves it
    quiet az containerapp create -g "$RG" -n "$name" --environment "$ENV_NAME" --image "$image" \
      --revisions-mode single --ingress "$ingress" --target-port 8080 --transport auto "${extra[@]}" \
      --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
      --registry-server ghcr.io --registry-username "$GHCR_USER" --registry-password "$(ghcr_token)" \
      --secrets "${secret_args[@]}" --tags "${TAGS[@]}" service="$app" || die "create $name failed"
  else
    log "   update secrets $name"
    quiet az containerapp secret set -g "$RG" -n "$name" --secrets "${secret_args[@]}" || die "secret set $name failed"
    quiet az containerapp registry set -g "$RG" -n "$name" --server ghcr.io --username "$GHCR_USER" --password "$(ghcr_token)" || die "registry set $name failed"
  fi
  # ingress (idempotent): external only for the edge
  if [[ "$ingress" == internal ]]; then
    az containerapp ingress enable -g "$RG" -n "$name" --type internal --target-port 8080 --transport auto --allow-insecure -o none
  else
    az containerapp ingress enable -g "$RG" -n "$name" --type external --target-port 8080 --transport auto -o none
  fi
  # template: image, env, resources, probes, scale (PATCH; no new revision when nothing changed)
  local id body
  id=$(az containerapp show -g "$RG" -n "$name" --query id -o tsv)
  body=$(mktemp); template_json "$name" "$image" "$ready" "$@" > "$body"
  az rest --method patch --url "https://management.azure.com${id}?api-version=2025-01-01" --body @"$body" -o none
  rm -f "$body"
  # verification (names only, never values)
  local names; names=$(az containerapp secret list -g "$RG" -n "$name" --query "[].name" -o tsv | tr '\n' ' ')
  for s in "${wanted[@]}"; do [[ " $names " == *" $s "* ]] || die "$name lost secret $s after PATCH"; done
  az containerapp show -g "$RG" -n "$name" --query "{img:properties.template.containers[0].image,cpu:properties.template.containers[0].resources.cpu,min:properties.template.scale.minReplicas,max:properties.template.scale.maxReplicas,ingress:properties.configuration.ingress.external,probes:length(properties.template.containers[0].probes || \`[]\`)}" -o tsv \
    | { read -r img cpu min max ext probes; log "     image=${img##*/} cpu=$cpu replicas=$min..$max external=$ext probes=$probes secrets=[$names]"; }
}

COMMON=(ASPNETCORE_ENVIRONMENT=Production OpenApi__Enabled=false DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
        "Auth__Supabase__ProjectUrl=$SUPABASE_URL" Edge__Key=secretref:hms-edge-key)

log "5. internal services"
for s in "${SERVICES[@]}"; do
  deploy_app "$s" internal /health/ready hms-db,hms-edge-key "${COMMON[@]}" \
    ConnectionStrings__HmsDatabase=secretref:hms-db "Database__MaxPoolSize=$POOL_SIZE" \
    Outbox__Dispatcher__Enabled=false
done

log "6. edge (external)"
# Cors__AllowedOrigins__0..2 overwrite ALL three entries of appsettings.json (env vars merge by index, so
# leaving index 2 would keep http://localhost:4173 in production). Previews come from AllowedOriginPatterns.
# Edge readiness probe = /health/live: its aggregate /health/ready calls every service and would keep them awake.
deploy_app edge external /health/live hms-edge-key "${COMMON[@]}" \
  "Cors__AllowedOrigins__0=$CORS_0" "Cors__AllowedOrigins__1=$CORS_1" "Cors__AllowedOrigins__2=$CORS_0" \
  ReverseProxy__Clusters__identity__Destinations__primary__Address=http://ca-hms-identity/ \
  ReverseProxy__Clusters__patients__Destinations__primary__Address=http://ca-hms-patients/ \
  ReverseProxy__Clusters__scheduling__Destinations__primary__Address=http://ca-hms-scheduling/ \
  ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/ \
  ReverseProxy__Clusters__inventory__Destinations__primary__Address=http://ca-hms-inventory/

# ---------------------------------------------------------------------------------------------------
log "7. post-checks"
az resource list -g "$RG" --query "[].type" -o tsv | sort | uniq -c
bad=$(az resource list -g "$RG" --query "[?contains(type,'registries') || contains(type,'vaults') || contains(type,'components') || contains(type,'workloadProfiles')].name" -o tsv)
[[ -z "$bad" ]] || die "unexpected billable resource types in $RG: $bad"
if [[ "$LOGS" == "none" ]]; then
  la=$(az resource list -g "$RG" --resource-type Microsoft.OperationalInsights/workspaces --query "[].name" -o tsv)
  [[ -z "$la" ]] || log "   NOTE: LOGS=none but a workspace exists in $RG ($la); it no longer receives data from the environment"
fi
FQDN=$(az containerapp show -g "$RG" -n ca-hms-edge --query properties.configuration.ingress.fqdn -o tsv)
GATEWAY_URL="https://$FQDN"
log "   waiting for the edge (cold start up to 90 s)"
for _ in $(seq 1 18); do
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$GATEWAY_URL/health/live" || true)
  [[ "$code" == 200 ]] && break; sleep 5
done
log "   edge /health/live -> ${code:-none}"
echo
echo "GATEWAY_URL=$GATEWAY_URL"
echo "Next: GATEWAY_URL=$GATEWAY_URL PUBLISHABLE_KEY=<sb_publishable_...> bash scripts/smoke/smoke-gateway.sh"
