#!/usr/bin/env bash
# Migration chain guard (DB review: "one migration chain"; docs/architecture/microservices.md).
#  1. every file in supabase/migrations is <14-digit version>_<snake_case>.sql
#  2. versions are unique (two services/branches must never claim the same version)
#  3. with BASE_REF set (PRs): files added on this branch must sort AFTER the newest migration on the
#     base branch, so hosted `supabase db push` never has to apply an out-of-order migration.
#     Rebase + renumber when another branch landed a newer version first.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
DIR=supabase/migrations
fail=0

mapfile -t files < <(ls -1 "$DIR"/*.sql | xargs -n1 basename | sort)
for f in "${files[@]}"; do
  if [[ ! "$f" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
    echo "::error file=$DIR/$f::migration filename must be <14-digit version>_<snake_case>.sql"; fail=1
  fi
done

dups=$(printf '%s\n' "${files[@]}" | cut -c1-14 | sort | uniq -d)
if [ -n "$dups" ]; then
  for v in $dups; do echo "::error::duplicate migration version $v: $(ls "$DIR"/"$v"_* | xargs -n1 basename | tr '\n' ' ')"; done
  fail=1
fi

if [ -n "${BASE_REF:-}" ]; then
  git fetch --no-tags --depth=1 origin "$BASE_REF" >/dev/null 2>&1 || true
  base_files=$(git ls-tree --name-only "origin/$BASE_REF" "$DIR/" 2>/dev/null | xargs -rn1 basename | sort || true)
  if [ -n "$base_files" ]; then
    base_max=$(printf '%s\n' "$base_files" | cut -c1-14 | sort | tail -1)
    for f in "${files[@]}"; do
      if ! printf '%s\n' "$base_files" | grep -qxF "$f"; then
        v=${f:0:14}
        if [[ ! "$v" > "$base_max" ]]; then
          echo "::error file=$DIR/$f::new migration $v is not newer than $BASE_REF's latest ($base_max); rebase and renumber"; fail=1
        fi
      fi
    done
    # A migration that exists on the base branch must not be renamed or deleted here.
    for f in $base_files; do
      [ -f "$DIR/$f" ] || { echo "::error::$f exists on $BASE_REF but not on this branch (applied migrations are immutable)"; fail=1; }
    done
  else
    echo "note: could not read $DIR on origin/$BASE_REF; skipped the ordering check"
  fi
fi

[ "$fail" = 0 ] && echo "migrations OK: ${#files[@]} files, unique 14-digit versions${BASE_REF:+, new ones newer than origin/$BASE_REF}"
exit "$fail"
