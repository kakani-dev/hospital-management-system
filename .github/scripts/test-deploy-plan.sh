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

for script in \
  .github/scripts/aca-rollout.sh \
  .github/scripts/aca-cleanup-azure.sh \
  .github/scripts/cleanup-github.sh \
  scripts/azure-oidc-setup.sh \
  scripts/smoke/post-deploy.sh
do
  bash -n "$script"
done

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
if grep -n 'az webapp' .github/scripts/aca-rollout.sh | grep -v 'appsettings list'; then
  fail "rollout may only read the legacy outbox setting"
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
                b'{"name":"scheduling","status":"Healthy"}]}'
            )
            if mode == "unhealthy":
                body = (
                    b'{"status":"Unhealthy","services":['
                    b'{"name":"identity","status":"Unhealthy"},'
                    b'{"name":"patients","status":"Healthy"},'
                    b'{"name":"scheduling","status":"Healthy"}]}'
                )
                return self._send(503, body)
            if mode == "identity-only":
                body = (
                    b'{"status":"Unhealthy","services":['
                    b'{"name":"identity","status":"Healthy"},'
                    b'{"name":"patients","status":"Unhealthy"},'
                    b'{"name":"scheduling","status":"Unhealthy"}]}'
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
if [[ "$all" == *"ingress.fqdn"* ]]; then
  echo "edge.example.test"
  exit 0
fi
if [[ "$all" == *"revision set-mode"* ]]; then exit 0; fi
if [[ "$all" == *"revision deactivate"* ]]; then exit 0; fi
if [[ "$all" == *"revision show"* ]]; then exit 1; fi
if [[ "$all" == *"ingress traffic set"* ]]; then exit 0; fi
if [[ "$all" == *"ingress traffic show"* ]]; then
  printf '[{"revisionName":"%s--sha-prevprevprev","weight":100}]\n' "$app"
  exit 0
fi
if [[ "$all" == *"secret set"* ]]; then exit 0; fi
if [[ "$all" == containerapp\ update* ]]; then
  mkdir -p "$AZ_STATE"
  : >"$AZ_STATE/$app.updated"
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
if [[ "$all" == *"Outbox__Dispatcher__Enabled"* ]]; then
  if [[ -n "${APP_OUTBOX_TRUE:-}" ]]; then echo true; else echo false; fi
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
      body='{"status":"Unhealthy","services":[{"name":"identity","status":"Unhealthy"},{"name":"patients","status":"Unhealthy"},{"name":"scheduling","status":"Unhealthy"}]}'
    else
      body='{"status":"Healthy","services":[{"name":"identity","status":"Healthy"},{"name":"patients","status":"Healthy"},{"name":"scheduling","status":"Healthy"}]}'
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
new_rev="ca-hms-patients--sha-0123456789ab"
grep -q -- "--revision-weight ${new_rev}=100" "$ROLLOUT_LOG" || fail "traffic did not move to $new_rev"
grep -q 'sha-prevprevprev=100' "$ROLLOUT_LOG" && fail "success run rolled traffic back" || true
echo "rollout success ok"

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
  HEALTH_TIMEOUT_SECONDS=1 FAIL_READY=1 run_rollout fail identity
grep -q 'revision deactivate' "$ROLLOUT_LOG" || fail "unhealthy revision was not deactivated"
grep -q 'ca-hms-identity--sha-prevprevprev=100' "$ROLLOUT_LOG" || fail "traffic was not restored"
echo "rollout health rollback ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  HEALTH_TIMEOUT_SECONDS=1 FAIL_LIVE_AFTER=1 run_rollout fail identity patients
for app in ca-hms-identity ca-hms-patients; do
  grep -q "${app}--sha-prevprevprev=100" "$ROLLOUT_LOG" || fail "$app was not restored"
  grep -q -- "--revision ${app}--sha-0123456789ab" "$ROLLOUT_LOG" || fail "$app new revision was not deactivated"
done
echo "rollout multi-service rollback ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  FAIL_ROUTE=1 run_rollout fail identity
grep -q 'ca-hms-identity--sha-prevprevprev=100' "$ROLLOUT_LOG" || fail "smoke failure did not restore traffic"
echo "rollout smoke rollback ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  B1_FORCE=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "B1 failure still updated a container app" || true
unset B1_FORCE
echo "rollout B1 guard ok"

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  NO_REGISTRY=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "missing registry still updated a container app" || true
unset NO_REGISTRY

SMTP_PASSWORD='smtp-test-value' SUPABASE_SERVICE_ROLE_KEY='role-test-value' \
  APP_OUTBOX_TRUE=1 run_rollout fail identity
grep -q 'containerapp update' "$ROLLOUT_LOG" && fail "enabled dispatcher still updated a container app" || true
unset APP_OUTBOX_TRUE
echo "rollout preflight guards ok"

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

echo "all deploy-plan checks passed"
