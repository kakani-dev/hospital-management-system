#!/usr/bin/env bash
# Fail when any needed job failed or was cancelled.
# Skipped and success are fine. The Supabase prototype is continue-on-error
# and must not fail the aggregate.
set -euo pipefail

if [ -z "${NEEDS:-}" ]; then
  echo "::error::NEEDS is empty"
  exit 1
fi

python3 - "$NEEDS" <<'PY'
import json, sys
needs = json.loads(sys.argv[1])
ignore = {"db-supabase-prototype"}
bad = []
for name in sorted(needs):
    info = needs[name] or {}
    result = info.get("result")
    if name in ignore:
        print(f"{name}: {result} (continue-on-error, ignored)")
        continue
    print(f"{name}: {result}")
    if result not in ("success", "skipped"):
        bad.append(f"{name}={result}")
if bad:
    print("::error::ci-ok failed: " + ", ".join(bad))
    sys.exit(1)
print("ci-ok: every needed job succeeded or was skipped")
PY
