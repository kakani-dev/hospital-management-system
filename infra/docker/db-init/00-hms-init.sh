#!/usr/bin/env bash
# Runs once when the docker-compose Postgres volume is first created.
# Applies the LOCAL Supabase shim, all migrations, the SYNTHETIC seed and the local API login role.
set -euo pipefail
PSQL=(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB")
"${PSQL[@]}" -f /supabase/scripts/local-supabase-shim.sql
for f in /supabase/migrations/*.sql; do
  echo "applying $f"
  "${PSQL[@]}" --single-transaction -f "$f"
done
"${PSQL[@]}" --single-transaction -f /supabase/seed.sql
# Local-only API login role (password is a dev placeholder; never reuse it elsewhere).
"${PSQL[@]}" -f /supabase/scripts/local-api-login-role.sql
