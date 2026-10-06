#!/usr/bin/env bash
# Runs once when the docker-compose Postgres volume is first created.
# Applies the LOCAL Supabase shim, all migrations and the SYNTHETIC seed.
set -euo pipefail
PSQL=(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB")
"${PSQL[@]}" -f /supabase/scripts/local-supabase-shim.sql
for f in /supabase/migrations/*.sql; do
  echo "applying $f"
  "${PSQL[@]}" --single-transaction -f "$f"
done
"${PSQL[@]}" --single-transaction -f /supabase/seed.sql
