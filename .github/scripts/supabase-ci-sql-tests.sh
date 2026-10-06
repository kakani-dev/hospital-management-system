#!/usr/bin/env bash
# Runs supabase/tests/*.sql against a database that is ALREADY migrated and seeded, e.g. the
# `supabase start` stack in the non-required `db-supabase-prototype` CI job (review Minor 9).
#
# Unlike supabase/scripts/run-sql-tests.sh, this does NOT create a database and does NOT
# install the local auth shim: the point is to exercise Supabase's real Postgres image,
# its predefined roles and the GoTrue-owned auth schema.
#
#   DB_URL           (required) connection to the migrated + seeded database
#   SKIP_LOGIN_ROLE  =1 to skip (re)creating the local-only hms_api_login role
#   LABEL            free text printed in the summary (e.g. "as supabase_admin")
#
# Safety: refuses any host other than localhost/127.0.0.1/::1. Never point it at a hosted
# Supabase project (it creates a role with a well-known local password).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${DB_URL:?set DB_URL to the local, already-migrated database}"
LABEL="${LABEL:-}"

host="$(python3 -c 'import sys,urllib.parse as u; print(u.urlsplit(sys.argv[1]).hostname or "")' "$DB_URL")"
case "$host" in
  localhost|127.0.0.1|::1) ;;
  *) echo "Refusing to run against non-local host '${host}'." >&2; exit 2 ;;
esac

PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" "$DB_URL" -Atc "select 'connected as ' || current_user || ' (superuser=' || r.rolsuper || ') to ' || version() from pg_roles r where r.rolname = current_user"

if [[ "${SKIP_LOGIN_ROLE:-0}" != "1" ]]; then
  echo "==> Ensuring local API login role (hms_api_login)"
  "${PSQL[@]}" "$DB_URL" -f "$ROOT/supabase/scripts/local-api-login-role.sql"
fi

echo "==> Installing test helpers"
"${PSQL[@]}" "$DB_URL" -f "$ROOT/supabase/tests/00_test_helpers.sql"

total=0
failed=()
for f in "$ROOT"/supabase/tests/[0-9][0-9]_*_test.sql; do
  name="$(basename "$f")"
  echo "==> ${name}"
  if out="$("${PSQL[@]}" "$DB_URL" -f "$f" 2>&1)"; then
    echo "$out" | sed -n 's/.*NOTICE:  \(ok - .*\)/    \1/p'
    n=$(echo "$out" | grep -c 'NOTICE:  ok - ' || true)
    total=$((total + n))
  else
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$out"
    echo "    FAILED: ${name}"
    failed+=("$name")
  fi
done

if (( ${#failed[@]} > 0 )); then
  echo "==> SQL tests ${LABEL}: ${total} assertions passed; FAILED files: ${failed[*]}"
  exit 1
fi
echo "==> SQL tests ${LABEL}: ${total} assertions passed, 0 failures"
