#!/usr/bin/env bash
# Grants platform-operator access (identity.platform_admins) to an EXISTING auth user, by email.
# Uses the database function identity.grant_platform_admin() (migration 20261019090000), which only
# the database owner may execute; it never creates accounts and grants NO tenant access.
#
#   APPROVED=1 DATABASE_URL=postgresql://<owner>@<host>:5432/<db> scripts/ops/grant-platform-admin.sh EMAIL
#
# Guard rails:
#   - refuses to run unless APPROVED=1 (an explicit, per-run human decision)
#   - needs DATABASE_URL (no default, so it can never hit a database by accident)
#   - prints the target host/database and the email, and asks for confirmation unless ASSUME_YES=1
#   - idempotent (ON CONFLICT DO NOTHING); fails if the email has no auth user yet (sign up first)
set -euo pipefail

email="${1:-}"
if [[ -z "$email" || "$email" != *@* ]]; then
  echo "usage: APPROVED=1 DATABASE_URL=... $0 EMAIL" >&2
  exit 2
fi
if [[ "${APPROVED:-0}" != "1" ]]; then
  echo "Refusing: set APPROVED=1 to confirm this grant was approved (platform operators can create and suspend hospitals)." >&2
  exit 3
fi
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Refusing: DATABASE_URL is not set." >&2
  exit 4
fi

target="$(psql -X -At "$DATABASE_URL" -c "select current_user || ' @ ' || coalesce(inet_server_addr()::text, 'local socket') || ' / ' || current_database()")"
echo "Target: ${target}"
echo "Grant platform operator to: ${email}"
if [[ "${ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Type GRANT to continue: " answer
  [[ "$answer" == "GRANT" ]] || { echo "Aborted." >&2; exit 5; }
fi

psql -X -v ON_ERROR_STOP=1 -v email="$email" "$DATABASE_URL" <<'SQL'
select identity.grant_platform_admin(:'email') as platform_admin_user_id;
select u.email, pa.created_on
  from identity.platform_admins pa join auth.users u on u.id = pa.user_id
 where not pa.is_deleted
 order by pa.created_on;
SQL
echo "Done. The operator signs in normally and lands on /platform."
