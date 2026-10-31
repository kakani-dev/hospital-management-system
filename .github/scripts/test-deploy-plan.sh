#!/usr/bin/env bash
# Local and CI checks for the deploy plan, smoke gate, rollback, and cleanup rules.
# Uses fake az/curl/gh. Does not call Azure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -m py_compile .github/scripts/service_changes.py .github/scripts/retention.py
python3 .github/scripts/service_changes.py --self-test
python3 .github/scripts/retention.py --self-test

# The revision Azure rejected was ca-hms-edge--sha-<40 hex> (57 characters).
# Every app's full revision name must stay <= 54. Image tags stay the full sha.
grep -q 'Azure allows at most 54' .github/scripts/aca-rollout.sh \
  || fail "rollout is missing the 54-character revision-name guard"
failed_sha=b896ba108cf95c3193dbf7598d2882659a8c0da9
failed_tag="sha-${failed_sha}"
[[ "${#failed_sha}" -eq 40 && "$failed_tag" == "sha-${failed_sha}" ]] || fail "image tag fixture was shortened"
for app in ca-hms-edge ca-hms-identity ca-hms-patients ca-hms-scheduling ca-hms-billing ca-hms-inventory ca-hms-privacy; do
  suffix="$(python3 .github/scripts/service_changes.py suffix --app "$app" --tag "$failed_tag")"
  name="${app}--${suffix}"
  [[ "$suffix" == "s-${failed_sha:0:12}" ]] || fail "$app suffix is '$suffix', expected s-${failed_sha:0:12}"
  [[ "$suffix" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || fail "$app suffix '$suffix' is not lowercase alnum/hyphen"
  [[ "$suffix" != *"--"* ]] || fail "$app suffix contains consecutive hyphens"
  if ((${#name} > 54)); then
    fail "revision name $name is ${#name} characters (Azure max is 54)"
  fi
  echo "revision $name (${#name} chars) image $failed_tag"
done

for script in \
  .github/scripts/aca-rollout.sh \
  .github/scripts/aca-live-tags.sh \
  .github/scripts/aca-cleanup-azure.sh \
  .github/scripts/cleanup-github.sh \
  scripts/azure-oidc-setup.sh \
  scripts/smoke/post-deploy.sh \
  scripts/smoke/vercel-web-smoke.sh \
  .github/scripts/web-deploy-plan.sh \
  scripts/verify.sh
do
  bash -n "$script"
done

# Rollout/plan scripts, the deploy workflow, and shared backend files select every app.
# A running image that is not this commit is included too. Image tags stay the full sha.
plan_sha="0123456789abcdef0123456789abcdef01234567"
[[ "${#plan_sha}" -eq 40 ]] || fail "plan sha fixture is ${#plan_sha} characters"
old_tag="sha-ca54690f712413349eebc2f105812223d16702d0"
plan_of() {
  local files live_file out
  files="$(mktemp)"
  printf '%s\n' "$@" >"$files"
  if [[ -n "${PLAN_LIVE:-}" ]]; then
    live_file="$PLAN_LIVE"
    out="$(python3 .github/scripts/service_changes.py plan \
      --sha "$plan_sha" --service "" --tag "" --files "$files" --live "$live_file")"
  else
    out="$(python3 .github/scripts/service_changes.py plan \
      --sha "$plan_sha" --service "" --tag "" --files "$files")"
  fi
  printf '%s\n' "$out"
}
expect_all() {
  local out="$1" why="$2"
  grep -q 'deploy=true' <<<"$out" || fail "$why did not deploy"
  grep -q 'build=true' <<<"$out" || fail "$why did not build"
  grep -q 'services=identity,patients,scheduling,billing,inventory,privacy,edge' <<<"$out" || fail "$why services were not the full set: $out"
  grep -q "tag=sha-${plan_sha}" <<<"$out" || fail "$why shortened the image tag: $out"
}
for path in \
  .github/scripts/aca-rollout.sh \
  .github/scripts/service_changes.py \
  .github/scripts/aca-live-tags.sh \
  .github/workflows/deploy-aca.yml \
  backend/Directory.Build.props \
  backend/global.json \
  backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj \
  backend/services/identity/packages.lock.json
do
  expect_all "$(plan_of "$path")" "$path"
done
only_patients="$(plan_of backend/services/patients/Dockerfile)"
grep -q 'services=patients' <<<"$only_patients" || fail "patients path selected '$only_patients'"
grep -q 'services=identity,patients,scheduling,billing,inventory,privacy,edge' <<<"$only_patients" && fail "patients path selected every service" || true
web_only="$(plan_of apps/web/src/App.tsx)"
grep -q 'deploy=false' <<<"$web_only" || fail "web-only change deployed: $web_only"
grep -q 'aca-live-tags.sh' .github/workflows/deploy-aca.yml || fail "plan job does not read running image tags"
grep -q -- '--live' .github/workflows/deploy-aca.yml || fail "plan job does not pass live tags"

stale_live="$(mktemp)"
for service in identity patients scheduling billing inventory privacy edge; do
  printf '%s\t%s\n' "$service" "$old_tag" >>"$stale_live"
done
PLAN_LIVE="$stale_live"
expect_all "$(plan_of docs/deploy.md)" "stale running images"
unset PLAN_LIVE

current_live="$(mktemp)"
for service in identity patients scheduling billing inventory privacy edge; do
  printf '%s\tsha-%s\n' "$service" "$plan_sha" >>"$current_live"
done
PLAN_LIVE="$current_live"
current_out="$(plan_of docs/deploy.md)"
grep -q 'deploy=false' <<<"$current_out" || fail "matching running images still deployed: $current_out"
unset PLAN_LIVE

bin="$(mktemp -d)"
cat >"$bin/az" <<'EOS'
#!/usr/bin/env bash
all="$*"
app=""
if [[ "$all" =~ (^|[[:space:]])-n[[:space:]](ca-hms-[a-z]+) ]]; then
  app="${BASH_REMATCH[2]}"
fi
service="${app#ca-hms-}"
if [[ "$all" == *"ingress traffic show"* ]]; then
  if [[ "$app" == "ca-hms-edge" ]]; then
    printf '[]\n'
  else
    printf '[{"revisionName":"%s--s-prev","weight":100}]\n' "$app"
  fi
  exit 0
fi
if [[ "$all" == *"revision show"* || "$all" == *"containerapp show"* ]]; then
  printf 'acrmedicorehmsdev.azurecr.io/hms-%s:sha-ca54690f712413349eebc2f105812223d16702d0\n' "$service"
  exit 0
fi
echo "unexpected az: $all" >&2
exit 1
EOS
chmod +x "$bin/az"
live_out="$(PATH="$bin:$PATH" bash .github/scripts/aca-live-tags.sh)"
for service in identity patients scheduling billing inventory privacy edge; do
  grep -qx "${service}"$'\t'"${old_tag}" <<<"$live_out" || fail "live tags missing $service: $live_out"
done
printf '%s\n' "$live_out" >"$stale_live"
PLAN_LIVE="$stale_live"
expect_all "$(plan_of apps/web/package-lock.json)" "live tags read from az"
unset PLAN_LIVE
echo "plan selects every service"

# Artifact uploads keep a retention window.
python3 - <<'PY'
from pathlib import Path
text = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
parts = text.split("uses: actions/upload-artifact@")
uploads = len(parts) - 1
if uploads < 1:
    raise SystemExit("ci.yml has no artifact uploads")
for part in parts[1:]:
    head = "\n".join(part.splitlines()[:15])
    if "retention-days:" not in head:
        raise SystemExit("upload-artifact is missing retention-days:\n" + head)
print(f"retention-days set on {uploads} upload(s)")
PY

if grep -RInE 'az webapp (config appsettings set|deploy|restart|update|start|stop|delete)' \
    .github/scripts .github/workflows scripts >/dev/null; then
  grep -RInE 'az webapp (config appsettings set|deploy|restart|update|start|stop|delete)' \
    .github/scripts .github/workflows scripts
  fail "legacy App Service must not be modified"
fi
if grep -n 'az webapp' .github/scripts/aca-rollout.sh; then
  fail "rollout must not call az webapp"
fi
if grep -n 'az webapp' .github/scripts/aca-cleanup-azure.sh .github/workflows/cleanup.yml .github/workflows/deploy-aca.yml; then
  fail "cleanup and the workflow must not call az webapp"
fi
if grep -RIn 'Outbox__Dispatcher__Enabled=true' \
    .github/workflows .github/scripts/aca-rollout.sh .github/scripts/aca-cleanup-azure.sh \
    scripts/azure-oidc-setup.sh scripts/smoke/post-deploy.sh; then
  fail "dispatcher must not be enabled"
fi
if grep -n 'ACA_DEPLOY_ENABLED' .github/workflows/deploy-aca.yml; then
  fail "deploy workflow is still gated on ACA_DEPLOY_ENABLED"
fi
if grep -n '^[[:space:]]*environment:' .github/workflows/deploy-aca.yml; then
  fail "deploy workflow must not wait on a GitHub environment"
fi
if grep -nE 'az ad app credential|az ad sp credential|client-secret' scripts/azure-oidc-setup.sh; then
  fail "OIDC setup must not create a client secret"
fi

deploy=.github/workflows/deploy-aca.yml
cleanup=.github/workflows/cleanup.yml
grep -q 'workflow_run:' "$deploy"
grep -q 'AZURE_CLIENT_ID' "$deploy"
grep -q 'cancel-in-progress:' "$deploy"
grep -q 'type=gha' "$deploy"
grep -q 'strategy:' "$deploy"
grep -q 'scripts/smoke/post-deploy.sh' .github/scripts/aca-rollout.sh
grep -q -- '--rollback-only' "$deploy"
grep -q 'smtp-password' .github/scripts/aca-rollout.sh
grep -q 'cron:' "$cleanup"
grep -q 'dry_run:' "$cleanup"
grep -q 'default: false' "$cleanup"
grep -q 'aca-cleanup-azure.sh' "$cleanup"
grep -q 'ACR_NAME: acrmedicorehmsdev' "$deploy"
grep -q 'ACR_NAME: acrmedicorehmsdev' "$cleanup"
grep -q 'acrmedicorehmsdev' scripts/azure-oidc-setup.sh
grep -q 'github-actions-main' scripts/azure-oidc-setup.sh
grep -q '249468300' scripts/azure-oidc-setup.sh
grep -q '1407449638' scripts/azure-oidc-setup.sh
grep -q 'repo:${OWNER}@${OWNER_ID}/${NAME}@${REPO_ID}:ref:refs/heads/main' scripts/azure-oidc-setup.sh
grep -q 'repo:kakani-dev@249468300/hospital-management-system@1407449638:ref:refs/heads/main' scripts/azure-oidc-setup.sh
grep -q 'repo:kakani-dev@249468300/hospital-management-system@1407449638:ref:refs/heads/main' docs/deploy.md
if grep -q 'SUBJECT="repo:${REPO}:ref:refs/heads/main"' scripts/azure-oidc-setup.sh docs/deploy.md; then
  fail "OIDC subject must include owner id and repository id"
fi
grep -q 'AcrPush' scripts/azure-oidc-setup.sh
grep -q 'AcrDelete' scripts/azure-oidc-setup.sh
grep -q 'Contributor' scripts/azure-oidc-setup.sh
grep -q 'AcrPull' scripts/azure-oidc-setup.sh
grep -q 'leaving the registry binding alone' scripts/azure-oidc-setup.sh
grep -q 'full 40-character commit sha' .github/workflows/deploy-aca.yml
grep -q 'def image_tag' .github/scripts/service_changes.py
if grep -nE 'hms-db=|replace-env-vars|registry set|identity assign' .github/scripts/aca-rollout.sh; then
  fail "rollout must not write hms-db, replace env vars, or rebind the registry"
fi
grep -q 'minReplicas is' .github/scripts/aca-rollout.sh

empty="$(mktemp)"
if python3 .github/scripts/retention.py delete-tags --keep 10 --protected "$empty" </dev/null 2>"$empty.err"; then
  fail "delete-tags must refuse an empty protected-tag file"
fi
grep -q 'refusing' "$empty.err"

# --- post-deploy smoke against a local server (real curl) ---------------------------------------
server_py="$(mktemp)"
cat >"$server_py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = os.environ.get("MODE", "ok")
state = {"live": 0}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health/live":
            state["live"] += 1
            if mode == "cold" and state["live"] == 1:
                return self._send(500, b"cold")
            return self._send(200, b'{"status":"Healthy"}')
        if path == "/health/ready":
            healthy = (
                b'{"status":"Healthy","services":['
                b'{"name":"identity","status":"Healthy"},'
                b'{"name":"patients","status":"Healthy"},'
                b'{"name":"scheduling","status":"Healthy"},'
                b'{"name":"billing","status":"Healthy"},'
                b'{"name":"inventory","status":"Healthy"},'
                b'{"name":"privacy","status":"Healthy"}]}'
            )
            if mode == "unhealthy":
                body = (
                    b'{"status":"Unhealthy","services":['
                    b'{"name":"identity","status":"Unhealthy"},'
                    b'{"name":"patients","status":"Healthy"},'
                    b'{"name":"scheduling","status":"Healthy"},'
                    b'{"name":"billing","status":"Healthy"},'
                    b'{"name":"inventory","status":"Healthy"}]}'
                )
                return self._send(503, body)
            if mode == "identity-only":
                body = (
                    b'{"status":"Unhealthy","services":['
                    b'{"name":"identity","status":"Healthy"},'
                    b'{"name":"patients","status":"Unhealthy"},'
                    b'{"name":"scheduling","status":"Unhealthy"},'
                    b'{"name":"billing","status":"Unhealthy"},'
                    b'{"name":"inventory","status":"Unhealthy"}]}'
                )
                return self._send(503, body)
            return self._send(200, healthy)
        if path.startswith("/api/v1/public/invites/"):
            if mode == "fallback":
                return self._send(404, b'{"detail":"No such API route.","code":"not_found"}')
            return self._send(404, b"")
        return self._send(500, b"no")

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

pids=()
cleanup_pids() {
  local pid
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup_pids EXIT

smoke() {
  local mode="$1" expect="$2"
  shift 2
  local portfile log pid i port status
  portfile="$(mktemp)"
  log="$(mktemp)"
  MODE="$mode" python3 "$server_py" >"$portfile" &
  pid=$!
  pids+=("$pid")
  for i in $(seq 1 50); do
    [[ -s "$portfile" ]] && break
    sleep 0.05
  done
  [[ -s "$portfile" ]] || fail "smoke server did not start"
  port="$(cat "$portfile")"
  set +e
  GATEWAY_URL="http://127.0.0.1:${port}" HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-3}" \
    SMOKE_INTERVAL_SECONDS=0 bash scripts/smoke/post-deploy.sh "$@" >"$log" 2>"$log.err"
  status=$?
  set -e
  kill "$pid" 2>/dev/null || true
  if [[ "$expect" == pass && "$status" != 0 ]]; then
    cat "$log" "$log.err" >&2
    fail "smoke mode=$mode expected pass, got $status"
  fi
  if [[ "$expect" == fail && "$status" == 0 ]]; then
    cat "$log" "$log.err" >&2
    fail "smoke mode=$mode expected fail"
  fi
}

smoke ok pass
smoke cold pass
smoke fallback fail
HEALTH_TIMEOUT_SECONDS=1 smoke unhealthy fail
HEALTH_TIMEOUT_SECONDS=1 smoke identity-only fail
SMOKE_MODE=health SMOKE_SERVICE=identity smoke identity-only pass
echo "post-deploy smoke ok"

# --- rollout with fake az and curl ---------------------------------------------------------------
run_rollout() {
  local expect="$1"
  shift
  local bin log state out err
  bin="$(mktemp -d)"
  log="$(mktemp)"
  state="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  cat >"$bin/az" <<'EOS'
#!/usr/bin/env bash
all="$*"
redacted="$all"
if [[ -n "${SMTP_PASSWORD:-}" ]]; then
  redacted="${redacted//${SMTP_PASSWORD}/***}"
fi
if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  redacted="${redacted//${SUPABASE_SERVICE_ROLE_KEY}/***}"
fi
echo "$redacted" >>"$AZ_LOG"
app=""
if [[ "$all" =~ (^|[[:space:]])-n[[:space:]](ca-hms-[a-z]+) ]]; then
  app="${BASH_REMATCH[2]}"
fi
if [[ "$all" == webapp\ config\ appsettings\ list* ]]; then
  if [[ -n "${B1_FORCE:-}" ]]; then echo true; else echo false; fi
  exit 0
fi
# #68 stale registry cleanup. STALE_GHCR lists the apps that still carry ghcr.io.
if [[ "$all" == *"registries[].server"* ]]; then
  [[ " ${STALE_GHCR:-} " == *" $app "* ]] && echo ghcr.io
  [[ -z "${STALE_NO_ACR:-}" ]] && echo acrmedicorehmsdev.azurecr.io
  exit 0
fi
if [[ "$all" == *"containers[0].image"* ]]; then
  if [[ -n "${STALE_IMAGE:-}" ]]; then echo "$STALE_IMAGE"; else echo "acrmedicorehmsdev.azurecr.io/hms-x:sha-0123456789ab"; fi
  exit 0
fi
if [[ "$all" == *"passwordSecretRef"* ]]; then echo "${STALE_REFS:-0}"; exit 0; fi
if [[ "$all" == *"registry remove"* || "$all" == *"secret remove"* ]]; then
  [[ -n "${STALE_REMOVE_FAIL:-}" ]] && exit 1
  exit 0
fi
if [[ "$all" == *"ingress.fqdn"* ]]; then
  echo "edge.example.test"
  exit 0
fi
if [[ "$all" == *"revision set-mode"* ]]; then exit 0; fi
if [[ "$all" == *"revision deactivate"* ]]; then exit 0; fi
if [[ "$all" == *"properties.runningState"* ]]; then
  if [[ -n "${ACTIVATION_FAIL:-}" && "$app" == "ca-hms-billing" ]]; then
    echo ActivationFailed
  elif [[ -n "${AT_MAX_SCALE:-}" ]]; then
    echo RunningAtMaxScale
  else
    echo Running
  fi
  exit 0
fi
if [[ "$all" == *"revision show"* ]]; then exit 1; fi
if [[ "$all" == *"ingress enable"* ]]; then exit 0; fi
if [[ "$1" == "rest" ]]; then
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--body" && "$arg" == @* ]]; then
      echo "PATCH $(cat "${arg#@}")" >>"$AZ_LOG"
    fi
    prev="$arg"
  done
  exit 0
fi
if [[ "$all" == *"containerapp show"* && "$all" == *"--query id"* ]]; then
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-medicore-hms-dev/providers/Microsoft.App/containerApps/${app}"
  exit 0
fi
if [[ "$all" == *"containerapp show"* && "$all" == *"-o json"* ]]; then
  printf '%s\n' '{"properties":{"template":{"containers":[{"name":"app","image":"old","env":[{"name":"ConnectionStrings__HmsDatabase","secretRef":"hms-db"}]}],"scale":{"minReplicas":0,"maxReplicas":1}}}}'
  exit 0
fi
if [[ "$all" == *"ingress traffic set"* ]]; then exit 0; fi
if [[ "$all" == *"ingress traffic show"* ]]; then
  printf '[{"revisionName":"%s--sha-prevprevprev","weight":100}]\n' "$app"
  exit 0
fi
if [[ "$all" == *"secret list"* ]]; then
  if [[ -n "${NO_HMS_DB:-}" ]]; then
    printf 'hms-edge-key\n'
  else
    printf 'hms-db\nhms-edge-key\n'
  fi
  [[ " ${STALE_GHCR:-} " == *" $app "* ]] && printf 'ghcrio-kakani-dev\n'
  exit 0
fi
if [[ "$all" == *"minReplicas"* ]]; then
  if [[ -n "${IDENTITY_MIN_ZERO:-}" && "$app" == "ca-hms-identity" ]]; then echo 0; else echo 1; fi
  exit 0
fi
if [[ "$all" == *"maxReplicas"* ]]; then
  echo 1
  exit 0
fi
if [[ "$all" == *"secret set"* ]]; then exit 0; fi
if [[ "$all" == containerapp\ update* ]]; then
  mkdir -p "$AZ_STATE"
  if [[ -n "${IN_PROGRESS_ONCE:-}" && ! -f "$AZ_STATE/$app.busy" ]]; then
    : >"$AZ_STATE/$app.busy"
    echo "ERROR: (ContainerAppOperationInProgress) Cannot modify a container app '$app'" >&2
    exit 1
  fi
  : >"$AZ_STATE/$app.updated"
  exit 0
fi
if [[ "$all" == *"provisioningState"* ]]; then
  suffix="$(python3 "$ROOT/.github/scripts/service_changes.py" suffix --app "$app" --tag "$IMAGE_TAG")"
  n=0
  [[ -f "$AZ_STATE/$app.prov" ]] && n="$(cat "$AZ_STATE/$app.prov")"
  n=$((n + 1))
  mkdir -p "$AZ_STATE"
  echo "$n" >"$AZ_STATE/$app.prov"
  if [[ -n "${PROVISION_LAG:-}" && "$n" -le "$PROVISION_LAG" ]]; then
    printf 'InProgress\n%s--sha-prevprevprev\n' "$app"
  else
    printf 'Succeeded\n%s--%s\n' "$app" "$suffix"
  fi
  exit 0
fi
if [[ "$all" == *"latestRevisionName"* ]]; then
  suffix="$(python3 "$ROOT/.github/scripts/service_changes.py" suffix --app "$app" --tag "$IMAGE_TAG")"
  echo "${app}--${suffix}"
  exit 0
fi
if [[ "$all" == *"registries"* ]]; then
  if [[ -n "${NO_REGISTRY:-}" ]]; then exit 0; fi
  echo system
  exit 0
fi
if [[ "$all" == *"Outbox__Dispatcher__DryRun"* ]]; then
  if [[ -n "${APP_OUTBOX_TRUE:-}" ]]; then echo false; else echo ""; fi
  exit 0
fi
if [[ "$all" == *"Outbox__Dispatcher__Enabled"* ]]; then
  if [[ -n "${APP_OUTBOX_TRUE:-}" || -n "${B1_FORCE:-}" ]]; then echo true; else echo false; fi
  exit 0
fi
if [[ "$all" == acr\ repository\ show* ]]; then exit 0; fi
echo "unexpected az: $redacted" >&2
exit 1
EOS
  cat >"$bin/curl" <<'EOS'
#!/usr/bin/env bash
url="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time|-w) shift 2 ;;
    -sS|-s|-S|-f) shift ;;
    http*) url="$1"; shift ;;
    *) echo "unexpected curl arg $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$(dirname "$out")"
code=200
body='{"status":"Healthy"}'
case "$url" in
  */health/live)
    n=0
    [[ -f "$CURL_STATE/live" ]] && n="$(cat "$CURL_STATE/live")"
    n=$((n + 1))
    echo "$n" >"$CURL_STATE/live"
    if [[ -n "${FAIL_LIVE_AFTER:-}" && "$n" -gt "$FAIL_LIVE_AFTER" ]]; then
      code=500
      body=down
    fi
    ;;
  */health/ready)
    if [[ -n "${FAIL_READY:-}" ]]; then
      code=503
      body='{"status":"Unhealthy","services":[{"name":"identity","status":"Unhealthy"},{"name":"patients","status":"Unhealthy"},{"name":"scheduling","status":"Unhealthy"},{"name":"billing","status":"Unhealthy"},{"name":"inventory","status":"Unhealthy"}]}'
    else
      names=(identity patients scheduling billing inventory privacy)
      if [[ -n "${EDGE_OMITS:-}" && ! -f "$CURL_STATE/ca-hms-edge.updated" ]]; then
        kept=()
        for name in "${names[@]}"; do
          [[ " ${EDGE_OMITS} " == *" ${name} "* ]] && continue
          kept+=("$name")
        done
        names=("${kept[@]}")
      fi
      body='{"status":"Healthy","services":['
      sep=""
      for name in "${names[@]}"; do
        body+="${sep}{\"name\":\"${name}\",\"status\":\"Healthy\"}"
        sep=,
      done
      body+=']}'
    fi
    ;;
  */api/v1/public/invites/*)
    if [[ -n "${FAIL_ROUTE:-}" ]]; then
      code=404
      body='{"detail":"No such API route."}'
    else
      code=404
      body=
    fi
    ;;
  *) echo "unexpected url $url" >&2; exit 1 ;;
esac
printf '%s' "$body" >"$out"
printf '%s' "$code"
EOS
  chmod +x "$bin/az" "$bin/curl"
  local status=0
  set +e
  PATH="$bin:$PATH" AZ_LOG="$log" AZ_STATE="$state" CURL_STATE="$state" ROOT="$ROOT" \
    IMAGE_TAG="${IMAGE_TAG:-sha-0123456789ab}" ROLLBACK_STATE="$state/rollback.tsv" \
    HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-2}" SMOKE_INTERVAL_SECONDS=0 \
    PROVISION_INTERVAL_SECONDS=0 AZ_RETRY_DELAY_SECONDS=0 PROVISION_TIMEOUT_SECONDS="${PROVISION_TIMEOUT_SECONDS:-5}" \
    bash .github/scripts/aca-rollout.sh "$@" >"$out" 2>"$err"
  status=$?
  set -e
  if [[ "$expect" == pass && "$status" != 0 ]]; then
    echo "---- stdout ----" >&2; cat "$out" >&2; echo "---- stderr ----" >&2; cat "$err" >&2
    echo "---- az ----" >&2; cat "$log" >&2
    fail "rollout expected pass, got $status"
  fi
  if [[ "$expect" == fail && "$status" == 0 ]]; then
    echo "---- stdout ----" >&2; cat "$out" >&2; echo "---- az ----" >&2; cat "$log" >&2
    fail "rollout expected fail"
  fi
  ROLLOUT_OUT="$out"
  ROLLOUT_ERR="$err"
  ROLLOUT_LOG="$log"
}

unset SMTP_PASSWORD SUPABASE_SERVICE_ROLE_KEY
IMAGE_TAG=sha-0123456789ab
run_rollout pass patients
grep -q 'ingress traffic set' "$ROLLOUT_LOG" || fail "success run did not shift traffic"
grep -q 'revision deactivate' "$ROLLOUT_LOG" && fail "success run deactivated a revision" || true
grep -q 'secret set' "$ROLLOUT_LOG" && fail "patients deploy stored an identity secret" || true
new_rev="ca-hms-patients--s-0123456789ab"
grep -q -- "--revision-suffix s-0123456789ab" "$ROLLOUT_LOG" || fail "short revision suffix was not used"
grep -q 'hms-patients:sha-0123456789ab' "$ROLLOUT_LOG" || fail "image tag was not kept in full"
grep -q -- "--revision-weight ${new_rev}=100" "$ROLLOUT_LOG" || fail "traffic did not move to $new_rev"
grep -q 'sha-prevprevprev=100' "$ROLLOUT_LOG" && fail "success run rolled traffic back" || true
grep -q 'ReverseProxy__Clusters__billing' "$ROLLOUT_LOG" && fail "a known service stamped edge cluster addresses" || true
grep -q 'ingress enable' "$ROLLOUT_LOG" && fail "a known service rewrote ingress" || true
echo "rollout success ok"

# #68: after a passing smoke, a stale ghcr.io binding and its secret are removed.
STALE_GHCR="ca-hms-patients" run_rollout pass patients
grep -q 'registry remove -g rg-medicore-hms-dev -n ca-hms-patients --server ghcr.io' "$ROLLOUT_LOG" || fail "stale ghcr.io binding was not removed"
grep -q 'secret remove -g rg-medicore-hms-dev -n ca-hms-patients --secret-names ghcrio-kakani-dev' "$ROLLOUT_LOG" || fail "stale ghcr secret was not removed"
grep 'registry remove' "$ROLLOUT_LOG" | grep -q 'azurecr.io' && fail "the ACR binding was removed" || true
# An app without the stale binding is untouched.
run_rollout pass patients
grep -q 'registry remove\|secret remove' "$ROLLOUT_LOG" && fail "cleanup touched an app with no stale binding" || true
# Serving image not from the ACR, or no ACR binding: keep the binding.
STALE_GHCR="ca-hms-patients" STALE_IMAGE="ghcr.io/kakani-dev/hms-patients:old" run_rollout pass patients
grep -q 'registry remove' "$ROLLOUT_LOG" && fail "removed ghcr.io while serving a ghcr image" || true
# Secret still referenced: keep it.
STALE_GHCR="ca-hms-patients" STALE_REFS=1 run_rollout pass patients
grep -q 'secret remove' "$ROLLOUT_LOG" && fail "removed a referenced secret" || true
# Failed health: no cleanup at all.
STALE_GHCR="ca-hms-patients" FAIL_READY=1 run_rollout fail patients
grep -q 'registry remove' "$ROLLOUT_LOG" && fail "cleanup ran after a failed smoke" || true
# Cleanup failure: non-zero exit but no rollback of the healthy deploy.
STALE_GHCR="ca-hms-patients" STALE_REMOVE_FAIL=1 run_rollout fail patients
grep -q 'revision deactivate' "$ROLLOUT_LOG" && fail "cleanup failure rolled back a healthy deploy" || true
grep -q 'sha-prevprevprev=100' "$ROLLOUT_LOG" && fail "cleanup failure restored old traffic" || true
echo "rollout stale registry cleanup ok"

# The update returns before Azure finishes provisioning: wait for the expected revision.
PROVISION_LAG=3 run_rollout pass patients
grep -q -- "--revision-weight ca-hms-patients--s-0123456789ab=100" "$ROLLOUT_LOG" || fail "lagging provisioning did not shift traffic"
# A concurrent operation on the app is retried, not treated as a failure.
IN_PROGRESS_ONCE=1 run_rollout pass patients
[[ "$(grep -c 'containerapp update' "$ROLLOUT_LOG")" -ge 2 ]] || fail "operation in progress was not retried"
# A revision that never becomes latest fails the rollout instead of shifting traffic.
PROVISION_LAG=1000 PROVISION_TIMEOUT_SECONDS=1 run_rollout fail patients
grep -q -- "--revision-weight ca-hms-patients--s-0123456789ab=100" "$ROLLOUT_LOG" && fail "traffic moved before provisioning finished" || true
echo "rollout provisioning wait ok"

run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "identity rolled without mail secrets" || true
echo "rollout identity secrets required ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' run_rollout pass identity
grep -q 'secret set' "$ROLLOUT_LOG" || fail "identity secrets were not stored"
grep -q 'smtp-password=' "$ROLLOUT_LOG" || fail "smtp-password secret missing"
grep -q 'supabase-service-role=' "$ROLLOUT_LOG" || fail "supabase-service-role secret missing"
grep -q 'Smtp__Password=secretref:smtp-password' "$ROLLOUT_LOG" || fail "SMTP env ref missing"
grep -q 'Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role' "$ROLLOUT_LOG" || fail "service role env ref missing"
grep -q 'Email__Dispatcher__Enabled=true' "$ROLLOUT_LOG" || fail "email dispatcher was not enabled on identity"
grep -q -- '--min-replicas 1' "$ROLLOUT_LOG" || fail "identity minReplicas was not kept at 1"
if grep -q 'hms-db=' "$ROLLOUT_LOG"; then
  fail "hms-db secret was overwritten"
fi
if grep -q 'replace-env-vars' "$ROLLOUT_LOG"; then
  fail "env vars were replaced"
fi
if grep 'containerapp update' "$ROLLOUT_LOG" | grep -q 'Outbox__Dispatcher__Enabled'; then
  fail "outbox dispatcher must stay untouched"
fi
if grep -v '::add-mask::' "$ROLLOUT_OUT" "$ROLLOUT_ERR" | grep -F 'smtp-test-value' >/dev/null; then
  fail "SMTP password leaked to the script output"
fi
if grep -v '::add-mask::' "$ROLLOUT_OUT" "$ROLLOUT_ERR" | grep -F 'role-test-value' >/dev/null; then
  fail "service role key leaked to the script output"
fi
if grep -F 'smtp-test-value' "$ROLLOUT_LOG" >/dev/null; then
  fail "SMTP password leaked to the az log"
fi
if grep -F 'role-test-value' "$ROLLOUT_LOG" >/dev/null; then
  fail "service role key leaked to the az log"
fi
echo "rollout identity secrets ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' run_rollout pass patients
grep -q 'secret set' "$ROLLOUT_LOG" && fail "patients deploy stored an identity secret" || true
unset SMTP_PASSWORD SUPABASE_SERVICE_ROLE_KEY
echo "rollout patients skip identity secrets ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  NO_HMS_DB=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "missing hms-db still updated identity" || true
grep -q 'secret set' "$ROLLOUT_LOG" && fail "missing hms-db still wrote secrets" || true
unset NO_HMS_DB
echo "rollout hms-db preserved ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  IDENTITY_MIN_ZERO=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "identity scale was changed" || true
unset IDENTITY_MIN_ZERO
echo "rollout identity minReplicas guard ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  HEALTH_TIMEOUT_SECONDS=1 FAIL_READY=1 run_rollout fail identity
grep -q 'revision deactivate' "$ROLLOUT_LOG" || fail "unhealthy revision was not deactivated"
grep -q 'ca-hms-identity--sha-prevprevprev=100' "$ROLLOUT_LOG" || fail "traffic was not restored"
echo "rollout health rollback ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  HEALTH_TIMEOUT_SECONDS=1 FAIL_LIVE_AFTER=1 run_rollout fail identity patients
for app in ca-hms-identity ca-hms-patients; do
  grep -q "${app}--sha-prevprevprev=100" "$ROLLOUT_LOG" || fail "$app was not restored"
  grep -q -- "--revision ${app}--s-0123456789ab" "$ROLLOUT_LOG" || fail "$app new revision was not deactivated"
  grep -q "hms-${app#ca-hms-}:sha-0123456789ab" "$ROLLOUT_LOG" || fail "$app image tag was shortened"
done
echo "rollout multi-service rollback ok"

# The name Azure rejected on main b896ba1. Rollback must deactivate s-<12 sha>,
# and the container image must still be the full sha- tag.
IMAGE_TAG="sha-${failed_sha}" HEALTH_TIMEOUT_SECONDS=1 FAIL_READY=1 run_rollout fail edge
grep -q "hms-edge:sha-${failed_sha}" "$ROLLOUT_LOG" || fail "full sha image tag was not used"
grep -q -- '--revision-suffix s-b896ba108cf9' "$ROLLOUT_LOG" || fail "short revision suffix was not used for the rejected sha"
grep -q -- '--revision ca-hms-edge--s-b896ba108cf9' "$ROLLOUT_LOG" || fail "rollback did not find the short revision name"
grep -q 'ca-hms-edge--sha-prevprevprev=100' "$ROLLOUT_LOG" || fail "traffic was not restored to the previous revision"
if grep -q "ca-hms-edge--sha-${failed_sha}" "$ROLLOUT_LOG"; then
  fail "rollout still used the 57-character revision name Azure rejected"
fi
IMAGE_TAG=sha-0123456789ab
unset FAIL_READY
echo "rollout full-sha revision name ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  FAIL_ROUTE=1 run_rollout fail identity
grep -q 'ca-hms-identity--sha-prevprevprev=100' "$ROLLOUT_LOG" || fail "smoke failure did not restore traffic"
echo "rollout smoke rollback ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  B1_FORCE=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "enabled dispatcher without DryRun still updated a container app" || true
unset B1_FORCE
echo "rollout B1 guard ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  NO_REGISTRY=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "missing registry still updated a container app" || true
unset NO_REGISTRY

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  APP_OUTBOX_TRUE=1 run_rollout pass identity
grep 'containerapp update' "$ROLLOUT_LOG" | grep -q 'Outbox__Dispatcher' && fail "rollout changed the dispatcher flags" || true
unset APP_OUTBOX_TRUE
echo "rollout preflight guards ok"

# A service the live edge does not list yet must not be judged through that edge.
# The edge revision in the same rollout stamps the cluster address, then smoke can see it.
SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  EDGE_OMITS=billing run_rollout pass identity patients scheduling billing edge
grep -q 'new to the live edge: billing' "$ROLLOUT_OUT" || fail "billing was not treated as new"
grep -q 'not checking it through the edge' "$ROLLOUT_OUT" || fail "billing was not deferred"
grep -q 'smoke health service=billing' "$ROLLOUT_OUT" && fail "billing was checked through the old edge" || true
grep -q 'smoke health service=all' "$ROLLOUT_OUT" || fail "the new edge did not prove every service"
grep -q 'SMOKE PASS (health + read-only invite preview)' "$ROLLOUT_OUT" || fail "new service rollout did not finish smoke"
grep -q -- '--target-port 8080' "$ROLLOUT_LOG" || fail "new service ingress was not moved to 8080"
grep -q '/health/live' "$ROLLOUT_LOG" || fail "new service is missing the live probe"
grep -q '/health/ready' "$ROLLOUT_LOG" || fail "new service is missing the ready probe"
grep -q '"port": 8080' "$ROLLOUT_LOG" || fail "new service probes are not on port 8080"
grep -q 'ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/' "$ROLLOUT_LOG" \
  || fail "edge revision did not set the billing cluster address"
grep -q 'ReverseProxy__Clusters__identity__Destinations__primary__Address=http://ca-hms-identity/' "$ROLLOUT_LOG" \
  || fail "edge revision did not set the identity cluster address"
billing_at="$(grep -n 'target-port 8080' "$ROLLOUT_LOG" | head -1 | cut -d: -f1)"
edge_at="$(grep -n 'ReverseProxy__Clusters__billing__Destinations__primary__Address' "$ROLLOUT_LOG" | head -1 | cut -d: -f1)"
[[ -n "$billing_at" && -n "$edge_at" && "$billing_at" -lt "$edge_at" ]] \
  || fail "billing port was not set before the edge learned the cluster (billing line $billing_at, edge line $edge_at)"
grep -q 'revision deactivate' "$ROLLOUT_LOG" && fail "new service success deactivated a revision" || true
unset EDGE_OMITS SMTP_PASSWORD SUPABASE_SERVICE_ROLE_KEY

# max replicas 1: Azure reports RunningAtMaxScale for a started revision. That is running.
SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  EDGE_OMITS=billing AT_MAX_SCALE=1 run_rollout pass identity patients scheduling billing edge
grep -q 'billing--s-[0-9a-f]* is RunningAtMaxScale' "$ROLLOUT_OUT" || fail "RunningAtMaxScale was not accepted"
unset EDGE_OMITS AT_MAX_SCALE SMTP_PASSWORD SUPABASE_SERVICE_ROLE_KEY
echo "rollout at-max-scale ok"
echo "rollout new service added ok"

EDGE_OMITS=billing run_rollout fail billing
grep -q 'must include the edge' "$ROLLOUT_ERR" || fail "billing-only deploy was not refused: $(cat "$ROLLOUT_ERR")"
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "refused new service still updated a container" || true
grep -q 'ingress enable' "$ROLLOUT_LOG" && fail "refused new service still changed ingress" || true
unset EDGE_OMITS
echo "rollout new service without edge ok"

EDGE_OMITS=billing ACTIVATION_FAIL=1 run_rollout fail billing edge
grep -q 'ActivationFailed' "$ROLLOUT_ERR" || fail "activation failure was not reported"
grep -q 'ca-hms-billing--s-0123456789ab' "$ROLLOUT_LOG" || fail "failed billing revision was not named"
grep -q 'revision deactivate' "$ROLLOUT_LOG" || fail "failed billing revision was not deactivated"
grep -q 'ReverseProxy__Clusters__billing' "$ROLLOUT_LOG" && fail "edge was updated after billing failed to start" || true
unset EDGE_OMITS ACTIVATION_FAIL
echo "rollout new service activation rollback ok"

run_rollout pass edge
grep -q 'ReverseProxy__Clusters__billing__Destinations__primary__Address=http://ca-hms-billing/' "$ROLLOUT_LOG" \
  || fail "a later edge deploy did not keep the billing cluster address"
grep -q 'replace-env-vars' "$ROLLOUT_LOG" && fail "edge deploy replaced env vars" || true
echo "rollout edge cluster addresses ok"

# --- azure cleanup with fake az -----------------------------------------------------------------
run_cleanup() {
  local bin log out err
  bin="$(mktemp -d)"
  log="$(mktemp)"
  out="$(mktemp)"
  err="$(mktemp)"
  cat >"$bin/az" <<'EOS'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$AZ_LOG"
app=""
if [[ "$all" =~ (^|[[:space:]])-n[[:space:]](ca-hms-[a-z]+) ]]; then
  app="${BASH_REMATCH[2]}"
fi
service="${app#ca-hms-}"
if [[ "$all" == *"containerapp show"* ]]; then
  python3 - "$service" <<'PY'
import json, sys
service = sys.argv[1]
print(json.dumps({
  "name": "ca-hms-" + service,
  "properties": {"template": {"containers": [{
    "image": "acrmedicorehmsdev.azurecr.io/hms-" + service + ":sha-000000000001"
  }]}}
}))
PY
  exit 0
fi
if [[ "$all" == *"revision list"* ]]; then
  python3 - "$service" <<'PY'
import json, sys
service = sys.argv[1]
image = "acrmedicorehmsdev.azurecr.io/hms-" + service + ":sha-000000000001"
def rev(name, created, traffic):
    return {
      "name": name,
      "properties": {
        "createdTime": created,
        "trafficWeight": traffic,
        "active": True,
        "runningState": "",
        "replicas": 0,
        "template": {"containers": [{"image": image}]},
      },
    }
print(json.dumps([
  rev("rev-new-5", "2026-05-05T00:00:00Z", 0),
  rev("rev-new-4", "2026-04-04T00:00:00Z", 0),
  rev("rev-new-3", "2026-03-03T00:00:00Z", 0),
  rev("rev-old", "2026-02-02T00:00:00Z", 0),
  rev("rev-serving", "2026-01-01T00:00:00Z", 100),
]))
PY
  exit 0
fi
if [[ "$all" == *"show-tags"* ]]; then
  python3 - <<'PY'
for i in range(12, 0, -1):
    print(f"sha-{i:012x}")
PY
  exit 0
fi
if [[ "$all" == acr\ repository\ show* ]]; then exit 0; fi
if [[ "$all" == acr\ repository\ delete* ]]; then exit 0; fi
if [[ "$all" == *"revision deactivate"* ]]; then exit 0; fi
echo "unexpected az: $all" >&2
exit 1
EOS
  chmod +x "$bin/az"
  set +e
  PATH="$bin:$PATH" AZ_LOG="$log" DRY_RUN="$1" bash .github/scripts/aca-cleanup-azure.sh >"$out" 2>"$err"
  local status=$?
  set -e
  if [[ "$status" != 0 ]]; then
    cat "$out" "$err" "$log" >&2
    fail "cleanup dry_run=$1 failed"
  fi
  CLEAN_OUT="$out"
  CLEAN_LOG="$log"
}

run_cleanup true
grep -q 'would delete hms-identity:sha-000000000002' "$CLEAN_OUT" || fail "dry-run did not name the stale tag"
grep -q 'would deactivate ca-hms-identity rev-old' "$CLEAN_OUT" || fail "dry-run did not name the old revision"
grep -q 'repository delete' "$CLEAN_LOG" && fail "dry-run deleted a tag" || true
grep -q 'revision deactivate' "$CLEAN_LOG" && fail "dry-run deactivated a revision" || true
grep -q 'sha-000000000001' <<<"$(grep 'would delete' "$CLEAN_OUT" || true)" && fail "dry-run would delete the deployed tag" || true
grep -q 'rev-serving' "$CLEAN_OUT" && fail "dry-run would deactivate the serving revision" || true
echo "cleanup dry-run ok"

run_cleanup false
grep -q 'repository delete' "$CLEAN_LOG" || fail "real cleanup did not delete"
grep -q 'hms-identity:sha-000000000002' "$CLEAN_LOG" || fail "real cleanup deleted the wrong tag"
if grep 'repository delete' "$CLEAN_LOG" | grep -q 'sha-000000000001'; then
  fail "real cleanup deleted the deployed tag"
fi
grep -q 'revision deactivate' "$CLEAN_LOG" || fail "real cleanup did not deactivate"
grep -q -- '--revision rev-old' "$CLEAN_LOG" || fail "old revision was not deactivated"
if grep 'revision deactivate' "$CLEAN_LOG" | grep -q 'rev-serving'; then
  fail "serving revision was deactivated"
fi
echo "cleanup real mode ok"

# --- github artifact/cache cleanup with fake gh -------------------------------------------------
run_github() {
  local bin log out
  bin="$(mktemp -d)"
  log="$(mktemp)"
  out="$(mktemp)"
  cat >"$bin/gh" <<'EOS'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == api\ -X\ DELETE* || "$all" == *"cache delete"* ]]; then
  echo "$all" >>"$GH_LOG"
  exit 0
fi
if [[ "$all" == *"artifacts"* ]]; then
  echo "111 old-artifact 2020-01-01T00:00:00Z"
  exit 0
fi
if [[ "$all" == *"cache list"* ]]; then
  echo "9 old-cache 2020-01-01T00:00:00Z"
  exit 0
fi
echo "unexpected gh: $all" >&2
exit 1
EOS
  chmod +x "$bin/gh"
  set +e
  PATH="$bin:$PATH" GH_LOG="$log" GH_TOKEN=test REPO=kakani-dev/hospital-management-system \
    MAX_AGE_DAYS=7 DRY_RUN="$1" bash .github/scripts/cleanup-github.sh >"$out" 2>"$out.err"
  local status=$?
  set -e
  if [[ "$status" != 0 ]]; then
    cat "$out" "$out.err" >&2
    fail "github cleanup dry_run=$1 failed"
  fi
  GH_OUT="$out"
  GH_LOG_FILE="$log"
}

run_github true
grep -q 'would delete artifact 111' "$GH_OUT" || fail "dry-run missed the artifact"
grep -q 'would delete cache 9' "$GH_OUT" || fail "dry-run missed the cache"
[[ ! -s "$GH_LOG_FILE" ]] || fail "dry-run called gh delete"
run_github false
grep -q 'api -X DELETE repos/kakani-dev/hospital-management-system/actions/artifacts/111' "$GH_LOG_FILE" \
  || fail "artifact was not deleted"
grep -q 'cache delete 9' "$GH_LOG_FILE" || fail "cache was not deleted"
echo "github cleanup ok"

if command -v jq >/dev/null; then
  jq -r '.artifacts[] | select(.expired == false and .created_at < "2026-01-01T00:00:00Z") | "\(.id) \(.name)"' <<'JSON' | grep -qx '1 old'
{"artifacts":[
  {"id":1,"name":"old","expired":false,"created_at":"2020-01-01T00:00:00Z"},
  {"id":2,"name":"new","expired":false,"created_at":"2099-01-01T00:00:00Z"},
  {"id":3,"name":"gone","expired":true,"created_at":"2020-01-01T00:00:00Z"}
]}
JSON
fi

web_plan="$(VERIFY_PATHS='apps/web/src/App.tsx' bash scripts/verify.sh --plan)"
[[ "$web_plan" == "web" ]] || fail "verify plan for web was '$web_plan'"
api_plan="$(VERIFY_PATHS='backend/Hms.slnx' bash scripts/verify.sh --plan)"
[[ "$api_plan" == "api" ]] || fail "verify plan for api was '$api_plan'"
none_plan="$(VERIFY_PATHS=$'docs/deploy.md\n.github/workflows/ci.yml' bash scripts/verify.sh --plan)"
[[ "$none_plan" == "none" ]] || fail "verify plan for docs was '$none_plan'"
both_plan="$(VERIFY_PATHS=$'apps/web/package.json\nbackend/global.json' bash scripts/verify.sh --plan)"
[[ "$both_plan" == $'web\napi' ]] || fail "verify plan for both was '$both_plan'"
grep -q 'scripts/verify.sh' lefthook.yml
grep -q 'pre-push:' lefthook.yml
grep -q 'scripts/verify.sh' CONTRIBUTING.md AGENTS.md .cursor/rules/verify-before-commit.mdc
echo "verify plan ok"

# --- Vercel web production deploy ---------------------------------------------------------------
web_workflow=.github/workflows/deploy-web.yml
[[ -f "$web_workflow" ]] || fail "missing $web_workflow"
grep -q 'name: Deploy web to Vercel' "$web_workflow"
grep -q 'workflow_run:' "$web_workflow"
grep -q 'workflows: \["CI"\]' "$web_workflow"
grep -q "head_branch == 'main'" "$web_workflow"
grep -q "conclusion == 'success'" "$web_workflow"
grep -q "workflow_run.event == 'push'" "$web_workflow"
grep -q 'workflow_dispatch:' "$web_workflow"
grep -q 'group: deploy-web' "$web_workflow"
grep -q 'cancel-in-progress: true' "$web_workflow"
grep -q 'vercel pull --yes --environment=production' "$web_workflow"
grep -q 'vercel build --prod' "$web_workflow"
grep -q 'vercel deploy --prebuilt --prod' "$web_workflow"
grep -q 'vercel rollback --yes' "$web_workflow"
grep -q 'secrets.VERCEL_TOKEN' "$web_workflow"
grep -q 'secrets.VERCEL_ORG_ID' "$web_workflow"
grep -q 'secrets.VERCEL_PROJECT_ID' "$web_workflow"
grep -q 'https://medicore-hms-three.vercel.app' "$web_workflow"
grep -q 'scripts/smoke/vercel-web-smoke.sh' "$web_workflow"
grep -q 'web-deploy-plan.sh' "$web_workflow"
grep -q 'github.event.workflow_run.head_sha' "$web_workflow" || fail "plan lost the triggering sha"
python3 - "$web_workflow" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
i = 0
while i < len(lines):
    if "uses: actions/checkout@" in lines[i]:
        block = [lines[i]]
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith("- "):
            block.append(lines[i])
            i += 1
        text = "\n".join(block)
        if "head_sha" in text or "actions/cache" in text or "cache:" in text:
            raise SystemExit("checkout must stay on the trusted ref and must not restore a cache:\n" + text)
        continue
    i += 1
if any(line.lstrip().startswith("cache:") or "actions/cache" in line for line in lines):
    raise SystemExit("deploy-web must not restore an Actions cache")
PY
if grep -n -- '--token' "$web_workflow"; then
  fail "VERCEL_TOKEN must come from the environment, not --token"
fi
if grep -nE '^[[:space:]]*environment:' "$web_workflow"; then
  fail "web deploy must not wait on a GitHub environment"
fi
if grep -nE '^[[:space:]]*paths:' "$web_workflow"; then
  fail "path filters belong in web-deploy-plan.sh; workflow_run has no paths filter"
fi
# Concurrency is on the deploy job only, so a non-web main push does not cancel it.
if [[ "$(grep -c 'cancel-in-progress:' "$web_workflow")" -ne 1 ]]; then
  fail "expected one cancel-in-progress group on the web deploy"
fi
if grep -nE 'team_[A-Za-z0-9]+|prj_[A-Za-z0-9]+' "$web_workflow" docs/runbooks/deploy-web.md; then
  fail "do not commit a Vercel team id or project id"
fi

plan_web() {
  local files
  files="$(mktemp)"
  printf '%s\n' "$@" >"$files"
  bash .github/scripts/web-deploy-plan.sh "$files"
}
[[ "$(plan_web apps/web/src/App.tsx)" == "deploy=true" ]] || fail "apps/web did not deploy"
[[ "$(plan_web apps/web/vercel.json)" == "deploy=true" ]] || fail "apps/web vercel.json did not deploy"
[[ "$(plan_web infra/vercel/vercel.json)" == "deploy=true" ]] || fail "infra/vercel did not deploy"
[[ "$(plan_web .github/workflows/deploy-web.yml)" == "deploy=true" ]] || fail "deploy-web.yml did not deploy"
[[ "$(plan_web backend/services/identity/Hms.Identity.Api/Program.cs)" == "deploy=false" ]] || fail "api path deployed web"
[[ "$(plan_web .github/workflows/ci.yml .github/workflows/deploy-aca.yml)" == "deploy=false" ]] || fail "other workflows deployed web"
[[ "$(plan_web docs/runbooks/deploy-web.md package.json)" == "deploy=false" ]] || fail "docs or root package.json deployed web"
[[ "$(plan_web backend/edge/Hms.Edge/Program.cs apps/web/src/main.tsx)" == "deploy=true" ]] || fail "mixed commit skipped web"
[[ "$(bash .github/scripts/web-deploy-plan.sh --force)" == "deploy=true" ]] || fail "--force did not deploy"
empty_files="$(mktemp)"
: >"$empty_files"
[[ "$(bash .github/scripts/web-deploy-plan.sh "$empty_files")" == "deploy=false" ]] || fail "empty diff deployed web"

python3 - <<'PY'
import json
from pathlib import Path
files = [Path("apps/web/vercel.json"), Path("infra/vercel/vercel.json")]
texts = [p.read_text() for p in files]
if texts[0] != texts[1]:
    raise SystemExit("apps/web/vercel.json and infra/vercel/vercel.json differ")
for path, text in zip(files, texts):
    data = json.loads(text)
    enabled = data["git"]["deploymentEnabled"]
    if not isinstance(enabled, dict):
        raise SystemExit(f"{path} deploymentEnabled must keep preview branches on")
    if enabled.get("main") is not False:
        raise SystemExit(f"{path} still auto-deploys main")
    extra = [key for key, value in enabled.items() if key != "main" and value is False]
    if extra:
        raise SystemExit(f"{path} disables preview branches: {extra}")
print("vercel.json: main git deploys off, previews on")
PY

grep -q 'VERCEL_TOKEN' docs/runbooks/deploy-web.md
grep -q 'VERCEL_ORG_ID' docs/runbooks/deploy-web.md
grep -q 'VERCEL_PROJECT_ID' docs/runbooks/deploy-web.md
grep -q 'git.deploymentEnabled.main' docs/runbooks/deploy-web.md
grep -q '.vercel/' .gitignore

smoke_port=8765
python3 - <<PY &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, fmt, *args):
        return
ThreadingHTTPServer(("127.0.0.1", $smoke_port), H).serve_forever()
PY
smoke_pid=$!
cleanup_smoke() { kill "$smoke_pid" 2>/dev/null || true; wait "$smoke_pid" 2>/dev/null || true; }
trap cleanup_smoke EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -o /dev/null "http://127.0.0.1:${smoke_port}/"; then
    break
  fi
  sleep 0.1
done
SMOKE_ATTEMPTS=2 SMOKE_SLEEP=0 bash scripts/smoke/vercel-web-smoke.sh "http://127.0.0.1:${smoke_port}/" \
  || fail "vercel web smoke rejected HTTP 200"
cleanup_smoke
trap - EXIT

python3 - <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"no"
        self.send_response(503)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return
ThreadingHTTPServer(("127.0.0.1", 8766), H).serve_forever()
PY
bad_pid=$!
cleanup_bad() { kill "$bad_pid" 2>/dev/null || true; wait "$bad_pid" 2>/dev/null || true; }
trap cleanup_bad EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8766/ || true)"
  [[ "$code" == "503" ]] && break
  sleep 0.1
done
if SMOKE_ATTEMPTS=2 SMOKE_SLEEP=0 bash scripts/smoke/vercel-web-smoke.sh http://127.0.0.1:8766/; then
  cleanup_bad
  trap - EXIT
  fail "vercel web smoke accepted HTTP 503"
fi
cleanup_bad
trap - EXIT
echo "vercel web deploy checks passed"

echo "all deploy-plan checks passed"
