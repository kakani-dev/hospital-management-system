#!/usr/bin/env bash
# Post-deploy smoke test, Sprint 1 + Sprint 2 (docs/runbooks/deploy-sprint-2-hosted.md §7).
#   Sprint 1: web bundle -> API, health live/ready, demo admin sign-in, GET /me, register + search a patient.
#   Sprint 2: practitioner + today's schedule (reused if present), free slots, book, check in (token),
#             queue board, in_consultation -> done (appointment -> completed), walk-in check-in + cancel.
# Writes to the target DB: 1 patient, <=1 practitioner, <=1 schedule, 1 appointment, 2 queue entries per run
# (all labelled SMOKE). Run ONLY against hosted after the CTO's go (runbook §8).
# Secrets: the demo password is READ FROM A FILE and never printed; the token stays in a shell variable.
set -euo pipefail
WEB_URL="${WEB_URL:-https://medicore-hms-three.vercel.app}"
# The public edge (ca-hms-edge). Do not default to the legacy App Service.
if [[ -z "${API_URL:-}" || "$API_URL" == *medicore-hms-api.azurewebsites.net* ]]; then
  echo "set API_URL to the public edge URL (docs/runbooks/monolith-cutover.md). This script does not call medicore-hms-api." >&2
  exit 2
fi
SUPABASE_URL="${SUPABASE_URL:-https://gvgomzogbzbjhlcsimrx.supabase.co}"
PUBLISHABLE_KEY="${PUBLISHABLE_KEY:?set PUBLISHABLE_KEY (public sb_publishable_... key)}"
DEMO_EMAIL="${DEMO_EMAIL:-admin@alpha.example}"
DEMO_PASSWORD_FILE="${DEMO_PASSWORD_FILE:-/home/box/.secrets/medicore-demo-admin}"
BRANCH_ID="${BRANCH_ID:-a1111111-0000-4000-8000-000000000001}"   # Alpha Main Campus (seed)
BRANCH_TZ="${BRANCH_TZ:-Asia/Kolkata}"                             # identity.branches.timezone of BRANCH_ID
PRACTITIONER_NAME="${PRACTITIONER_NAME:-SMOKE Practitioner}"
fail() { echo "FAIL: $*" >&2; exit 1; }
j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
today=$(TZ="$BRANCH_TZ" date +%F); weekday=$(TZ="$BRANCH_TZ" date +%u)

echo "1. web: $WEB_URL"
html=$(curl -fsS -m 30 "$WEB_URL/") || fail "web index not reachable"
js=$(grep -o '/assets/index-[A-Za-z0-9_-]*\.js' <<<"$html" | head -1)
curl -fsS -m 30 "$WEB_URL$js" -o "$TMP/bundle.js" || fail "bundle not reachable"
grep -qF "${API_URL#https://}" "$TMP/bundle.js" || fail "web bundle does not point at $API_URL"
code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "$WEB_URL/appointments") || true
[ "$code" = 200 ] || fail "SPA deep link /appointments -> HTTP $code"
echo "   ok (bundle -> API_URL, deep link /appointments 200)"

echo "2. api health (F1 may cold-start ~1 min)"
curl -fsS -m 120 "$API_URL/health/live" >/dev/null || fail "/health/live"
curl -fsS -m 60 "$API_URL/health/ready" >/dev/null || fail "/health/ready (DB)"
echo "   ok (live + ready)"

echo "3. sign in $DEMO_EMAIL"
[ -r "$DEMO_PASSWORD_FILE" ] || fail "demo password file missing"
tok=$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":open(sys.argv[2]).read().strip()}))' "$DEMO_EMAIL" "$DEMO_PASSWORD_FILE" \
  | curl -sS -m 30 -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
      -H "apikey: $PUBLISHABLE_KEY" -H "Content-Type: application/json" --data-binary @- | j 'd.get("access_token","")')
[ -n "$tok" ] || fail "sign-in returned no access_token"
echo "   ok (token received, not printed)"

H=(-H "Authorization: Bearer $tok" -H "Origin: $WEB_URL" -H "Content-Type: application/json")
# call METHOD PATH [BODY] -> body in $TMP/out.json, HTTP code on stdout
call() { local body=(); [ $# -ge 3 ] && body=(-d "$3")
  curl -sS -m 60 -o "$TMP/out.json" -w '%{http_code}' "${H[@]}" -X "$1" "$API_URL/api/v1$2" "${body[@]}"; }
expect() { local want="$1" got="$2" what="$3"; [[ " $want " == *" $got "* ]] || fail "$what -> HTTP $got: $(head -c 400 "$TMP/out.json")"; }

echo "4. GET /me"
expect 200 "$(call GET /me)" "/me"
echo "   ok: $(j '"email=%s roles=%s" % (d.get("email"), d.get("roles"))' <"$TMP/out.json")"

mrn="SMOKE-$(date +%Y%m%d%H%M%S)"
echo "5. register SMOKE TEST Patient ($mrn)"
expect 201 "$(call POST /patients "{\"mrn\":\"$mrn\",\"firstName\":\"SMOKE TEST\",\"lastName\":\"Patient\",\"sex\":\"unknown\",\"registeredBranchId\":\"$BRANCH_ID\"}")" "create patient"
pid=$(j 'd["id"]' <"$TMP/out.json"); echo "   ok id=$pid duplicateWarnings=$(j 'len(d.get("duplicateWarnings") or [])' <"$TMP/out.json")"

echo "6. search $mrn"
expect 200 "$(call POST /patients/search "{\"search\":\"$mrn\"}")" "search"
n=$(j 'len([p for p in (d.get("items") if isinstance(d,dict) else d) if p.get("mrn")=="'"$mrn"'"])' <"$TMP/out.json")
[ "$n" -ge 1 ] || fail "search did not return the new patient"; echo "   ok ($n match)"

echo "7. practitioner '$PRACTITIONER_NAME' (reuse or create)"
expect 200 "$(call GET "/practitioners?activeOnly=true")" "list practitioners"
prid=$(j 'next((p["id"] for p in d if p["displayName"]=="'"$PRACTITIONER_NAME"'"), "")' <"$TMP/out.json")
if [ -z "$prid" ]; then
  expect 201 "$(call POST /practitioners "{\"displayName\":\"$PRACTITIONER_NAME\",\"specialty\":\"General Medicine\"}")" "create practitioner"
  prid=$(j 'd["id"]' <"$TMP/out.json"); echo "   created $prid"
else echo "   reused $prid"; fi

echo "8. schedule for ISO weekday $weekday at branch (reuse or create 00:00-23:45 / 15 min)"
expect 200 "$(call GET "/schedules?branchId=$BRANCH_ID&practitionerId=$prid")" "list schedules"
sid=$(j 'next((s["id"] for s in d if s["weekday"]=='"$weekday"' and s["isActive"]), "")' <"$TMP/out.json")
if [ -z "$sid" ]; then
  expect 201 "$(call POST /schedules "{\"practitionerId\":\"$prid\",\"branchId\":\"$BRANCH_ID\",\"weekday\":$weekday,\"startTime\":\"00:00\",\"endTime\":\"23:45\",\"slotMinutes\":15,\"validFrom\":\"$today\"}")" "create schedule"
  sid=$(j 'd["id"]' <"$TMP/out.json"); echo "   created $sid"
else echo "   reused $sid"; fi

echo "9. free slots today ($today, $BRANCH_TZ)"
expect 200 "$(call GET "/slots?branchId=$BRANCH_ID&from=$today&to=$today&practitionerId=$prid")" "slots"
slot=$(j '(lambda s: s[0]["startsAt"]+" "+s[0]["endsAt"] if s else "")(d)' <"$TMP/out.json")
echo "   $(j 'len(d)' <"$TMP/out.json") free slot(s)"

if [ -n "$slot" ]; then
  read -r s_start s_end <<<"$slot"
  echo "10. book $s_start"
  expect 201 "$(call POST /appointments "{\"branchId\":\"$BRANCH_ID\",\"practitionerId\":\"$prid\",\"patientId\":\"$pid\",\"startsAt\":\"$s_start\",\"endsAt\":\"$s_end\",\"reason\":\"SMOKE booking\"}")" "book"
  aid=$(j 'd["id"]' <"$TMP/out.json"); st=$(j 'd["status"]' <"$TMP/out.json"); [ "$st" = booked ] || fail "status $st"
  echo "   ok appointment=$aid status=booked"

  echo "11. check in appointment"
  expect 201 "$(call POST "/appointments/$aid/check-in")" "check-in"
  qid=$(j 'd["queueEntryId"]' <"$TMP/out.json"); echo "   ok token=$(j 'd["tokenNo"]' <"$TMP/out.json") queueEntry=$qid"

  echo "12. queue board"
  expect 200 "$(call GET "/queue?branchId=$BRANCH_ID&date=$today")" "queue board"
  [ "$(j 'sum(1 for q in d if q["id"]=="'"$qid"'" and q["status"]=="waiting")' <"$TMP/out.json")" = 1 ] || fail "entry not waiting on board"
  echo "   ok (entry waiting, $(j 'len(d)' <"$TMP/out.json") on board)"

  echo "13. queue in_consultation -> done (appointment -> completed)"
  expect 200 "$(call PATCH "/queue/$qid" '{"status":"in_consultation"}')" "queue in_consultation"
  expect 200 "$(call PATCH "/queue/$qid" '{"status":"done"}')" "queue done"
  expect 200 "$(call GET "/appointments/$aid")" "get appointment"
  st=$(j 'd["status"]' <"$TMP/out.json"); [ "$st" = completed ] || fail "appointment status $st, expected completed"
  echo "   ok (appointment completed)"
else
  echo "10-13. SKIPPED: no free slot left today (late evening, branch time); walk-in still tested"
fi

echo "14. walk-in check-in + cancel"
expect 201 "$(call POST /queue/walk-in "{\"branchId\":\"$BRANCH_ID\",\"patientId\":\"$pid\",\"practitionerId\":\"$prid\"}")" "walk-in"
wq=$(j 'd["queueEntryId"]' <"$TMP/out.json"); echo "   ok token=$(j 'd["tokenNo"]' <"$TMP/out.json")"
expect 200 "$(call PATCH "/queue/$wq" '{"status":"cancelled"}')" "cancel walk-in"
echo "   ok (walk-in cancelled)"

echo "SMOKE PASS (sprint 1 + sprint 2)"
