#!/usr/bin/env bash
# Delete GitHub Actions artifacts older than MAX_AGE_DAYS and Actions caches not used since then.
# DRY_RUN=true prints the same decisions and deletes nothing. Uses GH_TOKEN / GITHUB_TOKEN only.
set -euo pipefail

: "${REPO:?set REPO (owner/name)}"
: "${GH_TOKEN:?set GH_TOKEN}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
DRY_RUN="${DRY_RUN:-false}"

[[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || { echo "max_age_days must be an integer" >&2; exit 1; }
[[ "$MAX_AGE_DAYS" -ge 1 ]] || { echo "max_age_days must be at least 1" >&2; exit 1; }
case "$DRY_RUN" in
  true|false) ;;
  *) echo "DRY_RUN must be true or false" >&2; exit 1 ;;
esac

cutoff="$(date -u -d "-${MAX_AGE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
echo "cutoff=$cutoff dry_run=$DRY_RUN"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! gh api --paginate "repos/$REPO/actions/artifacts?per_page=100" \
  --jq ".artifacts[] | select(.expired == false and .created_at < \"$cutoff\") | \"\(.id) \(.name) \(.created_at)\"" \
  >"$work/artifacts"; then
  echo "listing artifacts failed" >&2
  exit 1
fi
deleted_artifacts=0
while read -r id name created; do
  [[ -z "${id:-}" ]] && continue
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "would delete artifact $id ($name, created $created)"
  else
    echo "deleting artifact $id ($name, created $created)"
    gh api -X DELETE "repos/$REPO/actions/artifacts/$id"
  fi
  deleted_artifacts=$((deleted_artifacts + 1))
done <"$work/artifacts"
echo "artifacts: $deleted_artifacts older than $cutoff" | tee -a "$summary"

if ! gh cache list --repo "$REPO" --limit 1000 --json id,key,lastAccessedAt \
  --jq ".[] | select(.lastAccessedAt < \"$cutoff\") | \"\(.id) \(.key) \(.lastAccessedAt)\"" \
  >"$work/caches"; then
  echo "listing caches failed" >&2
  exit 1
fi
deleted_caches=0
while read -r id key last; do
  [[ -z "${id:-}" ]] && continue
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "would delete cache $id ($key, last used $last)"
  else
    echo "deleting cache $id ($key, last used $last)"
    gh cache delete "$id" --repo "$REPO"
  fi
  deleted_caches=$((deleted_caches + 1))
done <"$work/caches"
echo "caches: $deleted_caches unused since $cutoff" | tee -a "$summary"
