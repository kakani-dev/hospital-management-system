#!/usr/bin/env bash
# Smoke test of the YARP gateway on Azure Container Apps (docs/architecture/microservices-ci-and-aca-plan.md).
#
#   GATEWAY_URL=https://ca-hms-edge.<env>.centralindia.azurecontainerapps.io \
#   PUBLISHABLE_KEY=sb_publishable_... [SMOKE_AUTH=1] [SMOKE_WRITE=1] bash scripts/smoke/smoke-gateway.sh
#
# Levels:
#   SMOKE_AUTH=0              public checks only (health, CORS, isolation). Used by CI (no secrets there).
#   SMOKE_AUTH=1 (default)    + demo admin sign-in and GET /api/v1/me (read-only).
#   SMOKE_WRITE=1             + patient create/search and the Sprint 2 flow. WRITES to the hosted DB
#                               (1 patient, <=1 practitioner, <=1 schedule, 1 appointment, 2 queue entries,
#                               all labelled SMOKE), so run it only with the CTO's go.
# Secrets: the demo password is read from a file; the access token lives in a 600 temp file used as a curl
# header file (never on a command line, never printed).
set -euo pipefail
GATEWAY_URL="${GATEWAY_URL:?set GATEWAY_URL (https://ca-hms-edge...)}"; GATEWAY_URL="${GATEWAY_URL%/}"
WEB_ORIGIN="${WEB_ORIGIN:-https://medicore-hms-three.vercel.app}"
SUPABASE_URL="${SUPABASE_URL:-https://gvgomzogbzbjhlcsimrx.supabase.co}"
SMOKE_AUTH="${SMOKE_AUTH:-1}"
SMOKE_WRITE="${SMOKE_WRITE:-0}"
DEMO_EMAIL="${DEMO_EMAIL:-admin@alpha.example}"
DEMO_PASSWORD_FILE="${DEMO_PASSWORD_FILE:-/home/box/.secrets/medicore-demo-admin}"
BRANCH_ID="${BRANCH_ID:-a1111111-0000-4000-8000-000000000001}"   # Alpha Main Campus (seed)
BRANCH_TZ="${BRANCH_TZ:-Asia/Kolkata}"
PRACTITIONER_NAME="${PRACTITIONER_NAME:-SMOKE Practitioner}"
COLD_START_SECONDS="${COLD_START_SECONDS:-90}"
SERVICES=(identity patients scheduling)

case "$-" in *x*) echo "refusing: xtrace would print the token" >&2; exit 2 ;; esac
fail() { echo "FAIL: $*" >&2; exit 1; }
j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

# retry GET until HTTP 200 or COLD_START_SECONDS elapse (scale-to-zero: first call may wait for a replica)
wait_200() { local url="$1" what="$2" start code=""; start=$(date +%s)
  while :; do
    code=$(curl -sS -m 30 -o "$TMP/out.json" -w '%{http_code}' "$url" 2>/dev/null || true)
    [ "$code" = 200 ] && { echo "   ok $what (200 after $(( $(date +%s) - start ))s)"; return 0; }
    [ $(( $(date +%s) - start )) -ge "$COLD_START_SECONDS" ] && fail "$what -> HTTP ${code:-none} after ${COLD_START_SECONDS}s"
    sleep 5
  done; }

echo "1. gateway /health/live (cold-start tolerance ${COLD_START_SECONDS}s)"
wait_200 "$GATEWAY_URL/health/live" "/health/live"

echo "2. per-service readiness via the gateway aggregate /health/ready"
# The gateway does not route /health/* of individual services (only /api/v1/* prefixes). Its aggregate
# /health/ready GETs /health/ready on each cluster, which WAKES all three services. That is fine for a smoke
# test (the API checks below wake them anyway) but it must never be the ACA readiness probe of the edge.
wait_200 "$GATEWAY_URL/health/ready" "/health/ready (aggregate)"
for s in "${SERVICES[@]}"; do
  st=$(j 'next((x["status"] for x in d.get("services",[]) if x["name"]=="'"$s"'"), "missing")' <"$TMP/out.json")
  [ "$st" = Healthy ] || fail "service $s readiness: $st"
  echo "   ok $s Healthy"
done

echo "3. CORS preflight"
curl -sS -m 30 -o /dev/null -D "$TMP/h.txt" -X OPTIONS -H "Origin: $WEB_ORIGIN" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: authorization,content-type" \
  "$GATEWAY_URL/api/v1/patients" || fail "preflight request failed"
grep -qi "^access-control-allow-origin: $WEB_ORIGIN" "$TMP/h.txt" || fail "preflight from $WEB_ORIGIN not allowed"
echo "   ok $WEB_ORIGIN allowed"
curl -sS -m 30 -o /dev/null -D "$TMP/h.txt" -X OPTIONS -H "Origin: https://evil.example" \
  -H "Access-Control-Request-Method: POST" "$GATEWAY_URL/api/v1/patients" || true
if grep -qi '^access-control-allow-origin:' "$TMP/h.txt"; then fail "preflight from https://evil.example was allowed"; fi
echo "   ok foreign origin refused"

echo "4. isolation"
host="${GATEWAY_URL#https://}"; domain="${host#ca-hms-edge.}"
[ "$domain" != "$host" ] || fail "GATEWAY_URL host is not ca-hms-edge.<env domain>; cannot derive internal FQDNs"
for s in "${SERVICES[@]}"; do
  code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "https://ca-hms-$s.internal.$domain/health/live" 2>/dev/null || true)
  # ACA answers requests from outside the environment to an internal app with 404 (TLS still succeeds).
  case "$code" in 200|30?) fail "ca-hms-$s is reachable from the internet (HTTP $code)";; esac
  echo "   ok ca-hms-$s not reachable from outside (HTTP ${code:-000})"
done
code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "$GATEWAY_URL/internal/events" || true)
[ "$code" = 404 ] || fail "/internal/** must be 404 at the gateway (got $code)"
echo "   ok /internal/** blocked at the gateway (404)"
echo "   NOTE: 'service without X-Hms-Edge-Key is rejected (404)' cannot be tested from the box: the services are"
echo "         internal-only, and the images have no shell/curl for 'az containerapp exec'. It is covered by"
echo "         EdgeKeyMiddleware unit tests; verify once by hand if a debug container is ever added to the environment."

if [ "$SMOKE_AUTH" != 1 ]; then echo "SMOKE PASS (public checks only; SMOKE_AUTH=0)"; exit 0; fi

echo "5. sign in $DEMO_EMAIL (Supabase Auth)"
PUBLISHABLE_KEY="${PUBLISHABLE_KEY:?set PUBLISHABLE_KEY (public sb_publishable_... key)}"
[ -r "$DEMO_PASSWORD_FILE" ] || fail "demo password file missing"
python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":open(sys.argv[2]).read().strip()}))' "$DEMO_EMAIL" "$DEMO_PASSWORD_FILE" \
  | curl -sS -m 30 -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
      -H "apikey: $PUBLISHABLE_KEY" -H "Content-Type: application/json" --data-binary @- \
  | python3 -c 'import json,sys; t=json.load(sys.stdin).get("access_token",""); print(("Authorization: Bearer "+t) if t else "", end="")' > "$TMP/auth.h"
chmod 600 "$TMP/auth.h"
[ -s "$TMP/auth.h" ] || fail "sign-in returned no access_token"
echo "   ok (token received, kept in a 600 temp file, not printed)"

# call METHOD PATH [BODY] -> body in $TMP/out.json, HTTP code on stdout
call() { local body=(); [ $# -ge 3 ] && body=(-d "$3")
  curl -sS -m 60 -o "$TMP/out.json" -w '%{http_code}' -H @"$TMP/auth.h" -H "Origin: $WEB_ORIGIN" \
    -H "Content-Type: application/json" -H "X-Hms-Edge-Key: client-spoof-must-be-stripped" \
    -X "$1" "$GATEWAY_URL/api/v1$2" "${body[@]}"; }
expect() { local want="$1" got="$2" what="$3"; [[ " $want " == *" $got "* ]] || fail "$what -> HTTP $got: $(head -c 300 "$TMP/out.json")"; }

echo "6. GET /api/v1/me (identity service; client-sent X-Hms-Edge-Key must be stripped, not trusted)"
start=$(date +%s)
while :; do code=$(call GET /me || true); [ "$code" = 200 ] && break
  case "$code" in 502|503|504|000) ;; *) fail "/me -> HTTP $code: $(head -c 300 "$TMP/out.json")";; esac
  [ $(( $(date +%s) - start )) -ge "$COLD_START_SECONDS" ] && fail "/me still $code after ${COLD_START_SECONDS}s"; sleep 5; done
echo "   ok: $(j '"email=%s roles=%s" % (d.get("email"), d.get("roles"))' <"$TMP/out.json")"

if [ "$SMOKE_WRITE" != 1 ]; then echo "SMOKE PASS (read-only; set SMOKE_WRITE=1 for patient + Sprint 2 flow)"; exit 0; fi

today=$(TZ="$BRANCH_TZ" date +%F); weekday=$(TZ="$BRANCH_TZ" date +%u)
mrn="SMOKE-$(date +%Y%m%d%H%M%S)"
echo "7. register SMOKE TEST Patient ($mrn) (patients service)"
expect 201 "$(call POST /patients "{\"mrn\":\"$mrn\",\"firstName\":\"SMOKE TEST\",\"lastName\":\"Patient\",\"sex\":\"unknown\",\"registeredBranchId\":\"$BRANCH_ID\"}")" "create patient"
pid=$(j 'd["id"]' <"$TMP/out.json"); echo "   ok id=$pid"

echo "8. search $mrn"
expect 200 "$(call POST /patients/search "{\"search\":\"$mrn\"}")" "search"
n=$(j 'len([p for p in (d.get("items") if isinstance(d,dict) else d) if p.get("mrn")=="'"$mrn"'"])' <"$TMP/out.json")
[ "$n" -ge 1 ] || fail "search did not return the new patient"; echo "   ok ($n match)"

echo "9. practitioner '$PRACTITIONER_NAME' (scheduling service; reuse or create)"
expect 200 "$(call GET "/practitioners?activeOnly=true")" "list practitioners"
prid=$(j 'next((p["id"] for p in d if p["displayName"]=="'"$PRACTITIONER_NAME"'"), "")' <"$TMP/out.json")
if [ -z "$prid" ]; then
  expect 201 "$(call POST /practitioners "{\"displayName\":\"$PRACTITIONER_NAME\",\"specialty\":\"General Medicine\"}")" "create practitioner"
  prid=$(j 'd["id"]' <"$TMP/out.json"); echo "   created $prid"
else echo "   reused $prid"; fi

echo "10. schedule for ISO weekday $weekday (reuse or create 00:00-23:45 / 15 min)"
expect 200 "$(call GET "/schedules?branchId=$BRANCH_ID&practitionerId=$prid")" "list schedules"
sid=$(j 'next((s["id"] for s in d if s["weekday"]=='"$weekday"' and s["isActive"]), "")' <"$TMP/out.json")
if [ -z "$sid" ]; then
  expect 201 "$(call POST /schedules "{\"practitionerId\":\"$prid\",\"branchId\":\"$BRANCH_ID\",\"weekday\":$weekday,\"startTime\":\"00:00\",\"endTime\":\"23:45\",\"slotMinutes\":15,\"validFrom\":\"$today\"}")" "create schedule"
  echo "   created $(j 'd["id"]' <"$TMP/out.json")"
else echo "   reused $sid"; fi

echo "11. free slots today ($today, $BRANCH_TZ)"
expect 200 "$(call GET "/slots?branchId=$BRANCH_ID&from=$today&to=$today&practitionerId=$prid")" "slots"
slot=$(j '(lambda s: s[0]["startsAt"]+" "+s[0]["endsAt"] if s else "")(d)' <"$TMP/out.json")
if [ -n "$slot" ]; then
  read -r s_start s_end <<<"$slot"
  echo "12. book $s_start"
  expect 201 "$(call POST /appointments "{\"branchId\":\"$BRANCH_ID\",\"practitionerId\":\"$prid\",\"patientId\":\"$pid\",\"startsAt\":\"$s_start\",\"endsAt\":\"$s_end\",\"reason\":\"SMOKE booking\"}")" "book"
  aid=$(j 'd["id"]' <"$TMP/out.json"); [ "$(j 'd["status"]' <"$TMP/out.json")" = booked ] || fail "not booked"
  echo "   ok appointment=$aid"
  echo "13. check in"
  expect 201 "$(call POST "/appointments/$aid/check-in")" "check-in"
  qid=$(j 'd["queueEntryId"]' <"$TMP/out.json"); echo "   ok token=$(j 'd["tokenNo"]' <"$TMP/out.json")"
  echo "14. queue board + in_consultation -> done"
  expect 200 "$(call GET "/queue?branchId=$BRANCH_ID&date=$today")" "queue board"
  [ "$(j 'sum(1 for q in d if q["id"]=="'"$qid"'" and q["status"]=="waiting")' <"$TMP/out.json")" = 1 ] || fail "entry not waiting"
  expect 200 "$(call PATCH "/queue/$qid" '{"status":"in_consultation"}')" "in_consultation"
  expect 200 "$(call PATCH "/queue/$qid" '{"status":"done"}')" "done"
  expect 200 "$(call GET "/appointments/$aid")" "get appointment"
  [ "$(j 'd["status"]' <"$TMP/out.json")" = completed ] || fail "appointment not completed"
  echo "   ok (appointment completed)"
else
  echo "12-14. SKIPPED: no free slot left today (branch time); walk-in still tested"
fi

echo "15. walk-in check-in + cancel"
expect 201 "$(call POST /queue/walk-in "{\"branchId\":\"$BRANCH_ID\",\"patientId\":\"$pid\",\"practitionerId\":\"$prid\"}")" "walk-in"
wq=$(j 'd["queueEntryId"]' <"$TMP/out.json")
expect 200 "$(call PATCH "/queue/$wq" '{"status":"cancelled"}')" "cancel walk-in"
echo "   ok"
echo "SMOKE PASS (gateway + identity + patients + scheduling)"
