#!/usr/bin/env bash
# Schema ownership guard (ADR 0002).
#
# Service code (modules, services, platform) may mention another service's schema only in a
# file that contains "cross-schema: approved", and only on lines that are SQL/string literals.
# Comments without quotes are ignored.
#
# Migrations named <14-digit>_<service>_<what>.sql (service = identity|patients|scheduling|billing|inventory|platform)
# must set lock_timeout and statement_timeout. If they reference a schema they do not own, they
# need the same marker. With BASE_REF set, every migration added on the branch must use that
# name. Older filenames are immutable history and are not renamed.
#
# Forward-only content (a file that already exists on the base branch must be unchanged) lives
# in check-migration-versions.sh.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0

owned_schema_for() {
  case "$1" in
    identity) printf '%s\n' identity ;;
    patients) printf '%s\n' patient ;;
    scheduling) printf '%s\n' appointment ;;
    billing) printf '%s\n' billing ;;
    inventory) printf '%s\n' inventory ;;
    platform) printf '' ;;
    *) printf '' ;;
  esac
}

owner_for_path() {
  case "$1" in
    backend/modules/Identity/*|backend/services/identity/*) printf '%s' identity ;;
    backend/modules/Patients/*|backend/services/patients/*) printf '%s' patients ;;
    backend/modules/Appointments/*|backend/services/scheduling/*) printf '%s' scheduling ;;
    backend/modules/Billing/*|backend/services/billing/*) printf '%s' billing ;;
    backend/modules/Inventory/*|backend/services/inventory/*) printf '%s' inventory ;;
    backend/platform/*) printf '%s' platform ;;
    *) printf '' ;;
  esac
}

# schema.object on a line that contains a quote (a literal, not a doc comment).
foreign_literal() {
  local file="$1" owner="$2" owned line schema
  owned="$(owned_schema_for "$owner")"
  while IFS= read -r line; do
    [[ "$line" == *\"* ]] || continue
    while [[ "$line" =~ (identity|patient|appointment|messaging|audit|billing|inventory)\.[a-z_][a-z0-9_]* ]]; do
      schema="${BASH_REMATCH[1]}"
      if [[ "$schema" != "$owned" ]]; then
        return 0
      fi
      line="${line#*"${BASH_REMATCH[0]}"}"
    done
  done < "$file"
  return 1
}

while IFS= read -r -d '' file; do
  owner="$(owner_for_path "$file")"
  [[ -n "$owner" ]] || continue
  if grep -q 'cross-schema: approved' "$file"; then
    continue
  fi
  if foreign_literal "$file" "$owner"; then
    echo "::error file=$file::$owner code references another schema without 'cross-schema: approved'"
    fail=1
  fi
done < <(find backend/modules backend/services backend/platform -name '*.cs' -not -path '*/bin/*' -not -path '*/obj/*' -print0)

new_name='^[0-9]{14}_(identity|patients|scheduling|billing|inventory|platform)_[a-z0-9_]+\.sql$'

# PRs set BASE_REF. A local run and a push to main do not; compare with origin/main
# when that ref is already present. Never shallow-fetch over origin/$BASE_REF: a
# depth-1 update drops the parent commits this checkout was using.
if [[ -z "${BASE_REF:-}" ]] && git rev-parse --verify -q origin/main >/dev/null; then
  BASE_REF=main
fi
base_commit=""
if [[ -n "${BASE_REF:-}" ]]; then
  if git rev-parse --verify -q "origin/$BASE_REF" >/dev/null; then
    base_commit="origin/$BASE_REF"
  else
    git fetch --no-tags --depth=1 origin "$BASE_REF:refs/tmp/schema-ownership-base" >/dev/null 2>&1 || true
    if git rev-parse --verify -q refs/tmp/schema-ownership-base >/dev/null; then
      base_commit="refs/tmp/schema-ownership-base"
    fi
  fi
fi

for path in supabase/migrations/*.sql; do
  base="$(basename "$path")"
  on_base=0
  if [[ -n "$base_commit" ]] && git cat-file -e "$base_commit:supabase/migrations/$base" 2>/dev/null; then
    on_base=1
  fi
  # Applied files stay as they are (forward-only). The name, timeout, and approval
  # rules apply to migrations this branch adds.
  if [[ "$on_base" == 1 ]]; then
    continue
  fi
  if [[ -n "${BASE_REF:-}" && ! "$base" =~ $new_name ]]; then
    echo "::error file=$path::new migration must be named <ts>_<identity|patients|scheduling|billing|inventory|platform>_<what>.sql"
    fail=1
    continue
  fi
  [[ "$base" =~ $new_name ]] || continue

  service="${BASH_REMATCH[1]}"
  if ! grep -q 'lock_timeout' "$path" || ! grep -q 'statement_timeout' "$path"; then
    echo "::error file=$path::migration must set lock_timeout and statement_timeout"
    fail=1
  fi
  owned="$(owned_schema_for "$service")"
  if grep -q 'cross-schema: approved' "$path"; then
    continue
  fi
  # Strip SQL comments roughly so a mention inside an approved header is the only exception,
  # and a comment that names another schema still counts (the marker is the exception).
  if grep -E '(^|[^a-z_])(identity|patient|appointment|messaging|audit|billing|inventory)\.[a-z_]' "$path" \
      | grep -v 'cross-schema: approved' >/dev/null; then
    foreign=0
    while IFS= read -r schema; do
      [[ "$schema" == "$owned" ]] && continue
      foreign=1
    done < <(grep -oE '(identity|patient|appointment|messaging|audit|billing|inventory)\.[a-z_]' "$path" | cut -d. -f1 | sort -u)
    if [[ "$foreign" == 1 ]]; then
      echo "::error file=$path::$service migration touches another schema without '-- cross-schema: approved'"
      fail=1
    fi
  fi
done

if [[ "$fail" == 0 ]]; then
  echo "schema ownership OK"
fi
exit "$fail"
