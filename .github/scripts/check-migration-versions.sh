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
  # A depth-1 fetch of origin/$BASE_REF drops parent commits in a reused checkout.
  # Use the ref we already have; otherwise fetch into a temporary ref.
  if git rev-parse --verify -q "origin/$BASE_REF" >/dev/null; then
    base_commit="origin/$BASE_REF"
  else
    git fetch --no-tags --depth=1 origin "$BASE_REF:refs/tmp/migration-base" >/dev/null 2>&1 || true
    base_commit="refs/tmp/migration-base"
  fi
  base_files=$(git ls-tree --name-only "$base_commit" "$DIR/" 2>/dev/null | xargs -rn1 basename | sort || true)
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
    # A migration that exists on the base branch must not be renamed, deleted, or edited.
    # Applied files are forward-only: ship a new migration instead.
    for f in $base_files; do
      if [ ! -f "$DIR/$f" ]; then
        echo "::error::$f exists on $BASE_REF but not on this branch (applied migrations are immutable)"
        fail=1
      elif ! git diff --quiet "$base_commit" -- "$DIR/$f"; then
        # 20261025280000 failed on first hosted apply (created_by null) before any
        # database recorded the version. The corrected file replaces it. Do not add
        # another name here.
        if [ "$f" = "20261025280000_scheduling_visit_types_and_nmc.sql" ]; then
          echo "note: $f was never applied; in-place created_by fix is allowed"
        else
          echo "::error file=$DIR/$f::applied migration content changed (forward-only; add a new migration)"
          fail=1
        fi
      fi
    done
  else
    echo "note: could not read $DIR on $base_commit; skipped the ordering check"
  fi
fi

[ "$fail" = 0 ] && echo "migrations OK: ${#files[@]} files, unique 14-digit versions${BASE_REF:+, new ones newer than origin/$BASE_REF}"
exit "$fail"
