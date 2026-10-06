#!/usr/bin/env bash
# Smoke test of the REAL Supabase Auth (GoTrue) server calling the repo's
# identity.custom_access_token_hook, plus refresh-token rotation/reuse behaviour.
# Used by the non-required `db-supabase-prototype` CI job (review Minor 9 and Q5).
#
#   AUTH_URL         GoTrue base URL, e.g. http://127.0.0.1:54321/auth/v1 (via Kong) or
#                    http://127.0.0.1:9999 (GoTrue directly)
#   APIKEY           local publishable/anon key (sent as `apikey`; ignored by bare GoTrue)
#   DB_URL           admin connection to the same local database (adds the test membership)
#   EXPECTED_JWT_EXP optional: assert exp - iat equals this many seconds
#   REUSE_INTERVAL   refresh_token_reuse_interval configured on the stack (default 10)
#
# Safety: local hosts only. Uses a throwaway user with a random password on a throwaway stack.
set -euo pipefail

: "${AUTH_URL:?}" "${DB_URL:?}"
APIKEY="${APIKEY:-}"
REUSE_INTERVAL="${REUSE_INTERVAL:-10}"
ALPHA_TENANT="11111111-1111-4111-8111-111111111111"   # synthetic seed tenant (supabase/seed.sql)

for url in "$AUTH_URL" "$DB_URL"; do
  host="$(python3 -c 'import sys,urllib.parse as u; print(u.urlsplit(sys.argv[1]).hostname or "")' "$url")"
  case "$host" in localhost|127.0.0.1|::1) ;; *) echo "Refusing non-local host '${host}'." >&2; exit 2 ;; esac
done

pass=0
ok()   { echo "    ok - $*"; pass=$((pass + 1)); }
fail() { echo "    not ok - $*" >&2; exit 1; }

# POST JSON to GoTrue; prints "<http_status> <body>"
post() {
  local path="$1" body="$2"
  curl -sS -o /tmp/hms-smoke-body.json -w '%{http_code}' -X POST "${AUTH_URL}${path}" \
    -H 'Content-Type: application/json' ${APIKEY:+-H "apikey: ${APIKEY}"} -d "$body"
}
claims() { # decode the JWT payload (base64url) to JSON
  python3 -c 'import sys,base64,json; p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))' "$1"
}

email="smoke-$(date +%s)-$RANDOM@example.test"
password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"

echo "==> GoTrue health"
curl -fsS ${APIKEY:+-H "apikey: ${APIKEY}"} "${AUTH_URL}/health" >/dev/null || fail "GoTrue /health not reachable"
ok "GoTrue /health responds"

echo "==> Sign up a throwaway user (no memberships yet)"
code="$(post /signup "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')")"
[[ "$code" == "200" ]] || { cat /tmp/hms-smoke-body.json >&2; fail "signup returned HTTP ${code}"; }
token="$(jq -r '.access_token // empty' /tmp/hms-smoke-body.json)"
user_id="$(jq -r '.user.id // .id // empty' /tmp/hms-smoke-body.json)"
[[ -n "$token" && -n "$user_id" ]] || { cat /tmp/hms-smoke-body.json >&2; fail "signup returned no session (are email confirmations off?)"; }
c="$(claims "$token")"
[[ "$(jq -r '.sub' <<<"$c")" == "$user_id" ]] || fail "token sub is not the new user"
ok "token sub is the new user"
[[ "$(jq -r 'has("tenant_id")' <<<"$c")" == "false" ]] || fail "user without memberships got a tenant_id claim"
ok "user without memberships gets no tenant_id claim (hook did not block sign-up)"

echo "==> Give the user an ACTIVE receptionist membership in the synthetic Alpha tenant"
psql -X -q -v ON_ERROR_STOP=1 "$DB_URL" \
  -v uid="$user_id" -v email="$email" -v tenant="$ALPHA_TENANT" <<'SQL'
insert into identity.user_profiles (id, email, display_name)
values (:'uid', :'email', 'CI smoke user (synthetic)') on conflict (id) do nothing;
insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
values (:'tenant', :'uid', null, 'receptionist', 'active');
SQL
ok "membership inserted"

echo "==> Password sign-in: the real GoTrue must call identity.custom_access_token_hook"
code="$(post '/token?grant_type=password' "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')")"
[[ "$code" == "200" ]] || { cat /tmp/hms-smoke-body.json >&2; fail "password sign-in returned HTTP ${code}"; }
token="$(jq -r '.access_token' /tmp/hms-smoke-body.json)"
rt1="$(jq -r '.refresh_token' /tmp/hms-smoke-body.json)"
c="$(claims "$token")"
echo "    claims (subset): $(jq -c '{iss,aud,role,tenant_id,hms_roles,branch_ids,exp_minus_iat:(.exp-.iat)}' <<<"$c")"
[[ "$(jq -r '.tenant_id' <<<"$c")" == "$ALPHA_TENANT" ]] || fail "tenant_id claim missing/wrong: hook not invoked or failed"
ok "hook stamped tenant_id = Alpha"
[[ "$(jq -r '.hms_roles | index("receptionist") != null' <<<"$c")" == "true" ]] || fail "hms_roles does not contain receptionist"
ok "hook stamped hms_roles = [receptionist]"
[[ "$(jq -r '.role' <<<"$c")" == "authenticated" ]] || fail "role claim is not authenticated"
ok "role claim is authenticated"
if [[ -n "${EXPECTED_JWT_EXP:-}" ]]; then
  [[ "$(jq -r '.exp - .iat' <<<"$c")" == "$EXPECTED_JWT_EXP" ]] || fail "exp - iat != ${EXPECTED_JWT_EXP}"
  ok "access token lifetime is ${EXPECTED_JWT_EXP}s (jwt_expiry applied)"
fi

echo "==> Refresh-token rotation and reuse detection (reuse interval ${REUSE_INTERVAL}s)"
code="$(post '/token?grant_type=refresh_token' "$(jq -nc --arg r "$rt1" '{refresh_token:$r}')")"
[[ "$code" == "200" ]] || { cat /tmp/hms-smoke-body.json >&2; fail "refresh returned HTTP ${code}"; }
rt2="$(jq -r '.refresh_token' /tmp/hms-smoke-body.json)"
[[ -n "$rt2" && "$rt2" != "null" && "$rt2" != "$rt1" ]] || fail "refresh did not rotate the refresh token"
ok "refresh rotated the refresh token"
[[ "$(claims "$(jq -r '.access_token' /tmp/hms-smoke-body.json)" | jq -r '.tenant_id')" == "$ALPHA_TENANT" ]] \
  || fail "refreshed token has no tenant_id (hook not run on refresh)"
ok "hook also runs on refresh (tenant_id present)"

# GoTrue lets a client replay the PARENT of the currently active refresh token (it lost the
# response) and hands back the active token instead of minting a new one. Reuse detection
# applies to anything older, so rotate once more before replaying the original token.
code="$(post '/token?grant_type=refresh_token' "$(jq -nc --arg r "$rt1" '{refresh_token:$r}')")"
[[ "$code" == "200" && "$(jq -r '.refresh_token' /tmp/hms-smoke-body.json)" == "$rt2" ]] \
  || fail "replaying the parent of the active refresh token did not return the active token (HTTP ${code})"
ok "replaying the parent of the active token returns the SAME active token (lost-response allowance, no new token)"
code="$(post '/token?grant_type=refresh_token' "$(jq -nc --arg r "$rt2" '{refresh_token:$r}')")"
[[ "$code" == "200" ]] || { cat /tmp/hms-smoke-body.json >&2; fail "second refresh returned HTTP ${code}"; }
rt3="$(jq -r '.refresh_token' /tmp/hms-smoke-body.json)"
ok "second rotation issued a third refresh token"

sleep $((REUSE_INTERVAL + 2))
code="$(post '/token?grant_type=refresh_token' "$(jq -nc --arg r "$rt1" '{refresh_token:$r}')")"
[[ "$code" != "200" ]] || fail "replaying an old rotated refresh token after the reuse interval succeeded"
ok "replaying the original refresh token after ${REUSE_INTERVAL}s is rejected (HTTP ${code}: $(jq -r '.error_code // .error // .msg // empty' /tmp/hms-smoke-body.json))"
# Informational: GoTrue v2.197.0 (pinned by CLI 2.119.0) was observed locally to reject the
# replay but keep the session's newest refresh token valid (no family revocation), so reuse
# detection alone does not end a stolen session. See docs/runbooks/pr1-review-answers.md (Q5).
code="$(post '/token?grant_type=refresh_token' "$(jq -nc --arg r "$rt3" '{refresh_token:$r}')")"
if [[ "$code" == "200" ]]; then
  echo "    info - newest refresh token still valid after the replay (session NOT revoked by reuse detection)"
else
  echo "    info - newest refresh token rejected after the replay (HTTP ${code}): token family revoked"
fi

echo "==> Hook smoke test: ${pass} checks passed"
