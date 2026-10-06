#!/usr/bin/env bash
# Applies migrations + seed to a THROWAWAY database and runs the SQL tenant-isolation tests.
#
#   DATABASE_URL  admin connection to a server (default postgresql://postgres:postgres@localhost:5432/postgres)
#   TEST_DB       name of the throwaway database (default hms_sql_test) — it is DROPPED and recreated.
#
# Never point this at a real Supabase project: it drops TEST_DB and installs a local auth shim.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
TEST_DB="${TEST_DB:-hms_sql_test}"
TEST_URL="${ADMIN_URL%/*}/${TEST_DB}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

echo "==> Recreating database ${TEST_DB}"
"${PSQL[@]}" "$ADMIN_URL" -c "drop database if exists ${TEST_DB} with (force);" -c "create database ${TEST_DB};"

echo "==> Installing local Supabase shim (roles, auth schema)"
"${PSQL[@]}" "$TEST_URL" -f "$ROOT/scripts/local-supabase-shim.sql"

echo "==> Applying migrations"
for f in "$ROOT"/migrations/*.sql; do
  echo "    - $(basename "$f")"
  "${PSQL[@]}" "$TEST_URL" --single-transaction -f "$f"
done

echo "==> Seeding synthetic data"
"${PSQL[@]}" "$TEST_URL" --single-transaction -f "$ROOT/seed.sql"

echo "==> Ensuring local API login role (hms_api_login)"
"${PSQL[@]}" "$TEST_URL" -f "$ROOT/scripts/local-api-login-role.sql"

echo "==> Installing test helpers"
"${PSQL[@]}" "$TEST_URL" -f "$ROOT/tests/00_test_helpers.sql"

total=0
for f in "$ROOT"/tests/[0-9][0-9]_*_test.sql; do
  echo "==> $(basename "$f")"
  out="$("${PSQL[@]}" "$TEST_URL" -f "$f" 2>&1)" || { echo "$out"; echo "FAILED: $(basename "$f")"; exit 1; }
  echo "$out" | sed -n 's/.*NOTICE:  \(ok - .*\)/    \1/p'
  n=$(echo "$out" | grep -c 'NOTICE:  ok - ' || true)
  total=$((total + n))
done

echo "==> SQL tests passed: ${total} assertions, 0 failures"
