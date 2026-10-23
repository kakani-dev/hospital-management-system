#!/usr/bin/env bash
# Post-deploy gate for the public edge. No secrets, no writes.
#
#   GATEWAY_URL=https://ca-hms-edge.<env>.centralindia.azurecontainerapps.io \
#     bash scripts/smoke/post-deploy.sh
#
# SMOKE_MODE=full (default) requires:
#   GET /health/live                         -> 200
#   GET /health/ready                        -> 200 and identity, patients, scheduling, billing Healthy
#   GET /api/v1/public/invites/<64 zeros>    -> 404 from the identity service (read-only;
#                                               the unknown token is not a gateway "no such route")
# SMOKE_MODE=health skips the invite call.
# SMOKE_SERVICE=all (default) | identity | patients | scheduling | billing
#   In health mode, a single service only has to be Healthy (the aggregate may still be 503
#   while another service is rolling). full mode always requires every service.
#
# Cold start: scale-to-zero replicas can take a couple of minutes. Retries stay inside
# HEALTH_TIMEOUT_SECONDS (default 150).
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:?set GATEWAY_URL}"
GATEWAY_URL="${GATEWAY_URL%/}"
SMOKE_MODE="${SMOKE_MODE:-full}"
SMOKE_SERVICE="${SMOKE_SERVICE:-all}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-150}"
SMOKE_INTERVAL_SECONDS="${SMOKE_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
INVITE_TOKEN="0000000000000000000000000000000000000000000000000000000000000000"

case "$SMOKE_MODE" in
  full|health) ;;
  *) echo "SMOKE_MODE must be full or health" >&2; exit 2 ;;
esac
case "$SMOKE_SERVICE" in
  all|identity|patients|scheduling|billing) ;;
  *) echo "SMOKE_SERVICE must be all, identity, patients, scheduling, or billing" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

get() {
  # url -> body in $tmp/body, HTTP code on stdout (000 when curl could not connect)
  local code
  : >"$tmp/body"
  code="$(curl -sS --max-time "$CURL_MAX_TIME" -o "$tmp/body" -w '%{http_code}' "$1" 2>/dev/null || true)"
  if [[ -z "$code" ]]; then
    echo 000
  else
    echo "$code"
  fi
}

service_ready() {
  # $1 is all | identity | patients | scheduling | billing. Reads $tmp/body.
  python3 - "$1" "$tmp/body" <<'PY'
import json, sys
want, path = sys.argv[1], sys.argv[2]
try:
    document = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(1)
need = ["identity", "patients", "scheduling", "billing"] if want == "all" else [want]
found = {item.get("name"): item.get("status") for item in document.get("services") or []}
missing = [name for name in need if found.get(name) != "Healthy"]
if missing:
    sys.stderr.write("unhealthy: " + ", ".join(f"{name}={found.get(name) or 'missing'}" for name in missing) + "\n")
    sys.exit(1)
PY
}

wait_until() {
  local what="$1"
  shift
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local last="none"
  while (( SECONDS <= deadline )); do
    if "$@"; then
      echo "   ok $what"
      return 0
    fi
    last="$what"
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep "$SMOKE_INTERVAL_SECONDS"
  done
  echo "FAIL: $last not healthy within ${HEALTH_TIMEOUT_SECONDS}s" >&2
  return 1
}

check_live() {
  local code
  code="$(get "$GATEWAY_URL/health/live")"
  [[ "$code" == "200" ]]
}

check_ready() {
  local code want="$1"
  code="$(get "$GATEWAY_URL/health/ready")"
  if [[ "$want" == "all" && "$code" != "200" ]]; then
    return 1
  fi
  # A single service may already be Healthy while the aggregate is still 503.
  if [[ "$want" != "all" && "$code" != "200" && "$code" != "503" ]]; then
    return 1
  fi
  service_ready "$want"
}

check_invite() {
  local code
  code="$(get "$GATEWAY_URL/api/v1/public/invites/$INVITE_TOKEN")"
  if [[ "$code" == "404" ]] && ! grep -q 'No such API route' "$tmp/body"; then
    return 0
  fi
  # Cold start and upstream restarts are worth another try. A missing route is not.
  if [[ "$code" == "404" ]] && grep -q 'No such API route' "$tmp/body"; then
    echo "FAIL: /api/v1/public/invites is not routed (gateway fallback)" >&2
    return 2
  fi
  case "$code" in
    000|502|503|504) return 1 ;;
  esac
  echo "FAIL: read-only invite preview -> HTTP $code" >&2
  head -c 300 "$tmp/body" >&2 || true
  echo >&2
  return 2
}

echo "smoke $SMOKE_MODE service=$SMOKE_SERVICE $GATEWAY_URL"
wait_until "/health/live" check_live

ready_want="$SMOKE_SERVICE"
if [[ "$SMOKE_MODE" == "full" ]]; then
  ready_want="all"
fi
wait_until "/health/ready ($ready_want)" check_ready "$ready_want"

if [[ "$SMOKE_MODE" == "full" ]]; then
  # check_invite returns 2 for a hard failure. wait_until would keep retrying a hard failure
  # only when the command returns non-zero, so distinguish via a flag file.
  invite_once() {
    local status=0
    check_invite || status=$?
    if [[ "$status" == 2 ]]; then
      echo hard >"$tmp/invite-hard"
      return 0
    fi
    return "$status"
  }
  wait_until "GET /api/v1/public/invites (read-only 404)" invite_once
  if [[ -f "$tmp/invite-hard" ]]; then
    exit 1
  fi
  echo "SMOKE PASS (health + read-only invite preview)"
else
  echo "SMOKE PASS (health)"
fi
