#!/usr/bin/env bash
# Poll a URL until it returns HTTP 200, or fail.
# Used after a production Vercel deploy. No secrets, no writes.
#
#   bash scripts/smoke/vercel-web-smoke.sh https://medicore-hms-three.vercel.app
#
# SMOKE_ATTEMPTS (default 12) and SMOKE_SLEEP (default 5) control the wait.
# A redirect is not a pass: the production alias answers 200 directly.
set -euo pipefail

url="${1:?url}"
attempts="${SMOKE_ATTEMPTS:-12}"
sleep_s="${SMOKE_SLEEP:-5}"

[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { echo "SMOKE_ATTEMPTS must be a positive integer" >&2; exit 2; }

for i in $(seq 1 "$attempts"); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  echo "smoke $url -> ${code:-000} (${i}/${attempts})"
  if [[ "$code" == "200" ]]; then
    exit 0
  fi
  if [[ "$i" -lt "$attempts" ]]; then
    sleep "$sleep_s"
  fi
done

echo "smoke failed: $url never returned 200" >&2
exit 1
