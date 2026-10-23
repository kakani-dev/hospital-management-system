#!/usr/bin/env bash
# Delete stale Azure Container Registry sha- tags and deactivate old Container Apps revisions.
#
# Keeps, per image repository (hms-identity, hms-patients, hms-scheduling, hms-billing, hms-edge):
#   - the 10 newest sha-<hex> tags
#   - every tag currently deployed (app template, traffic, replicas, or a revision that is
#     Running/Activating), on every repository — a tag string in use is never deleted
# Keeps the newest 3 revisions of each container app, plus any revision that has traffic,
# replicas, or is still starting. Deactivates only active revisions outside that set.
#
# DRY_RUN=true prints the deletions and deactivations and does not perform them.
# Refuses to delete anything if a container app or its image cannot be read.
# Does not touch medicore-hms-api.
set -euo pipefail

case $- in
  *x*) echo "refusing: xtrace is not used here" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RG="${RESOURCE_GROUP:-rg-medicore-hms-dev}"
ACR_NAME="${ACR_NAME:-acrmedicorehmsdev}"
DRY_RUN="${DRY_RUN:-false}"
APPS=(ca-hms-identity ca-hms-patients ca-hms-scheduling ca-hms-billing ca-hms-edge)
REPOS=(hms-identity hms-patients hms-scheduling hms-billing hms-edge)

[[ "$RG" == "rg-medicore-hms-dev" ]] || { echo "::error::refusing resource group $RG" >&2; exit 1; }
[[ "$ACR_NAME" == "acrmedicorehmsdev" ]] || { echo "::error::refusing registry $ACR_NAME" >&2; exit 1; }
case "$DRY_RUN" in
  true|false) ;;
  *) echo "DRY_RUN must be true or false" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for app in "${APPS[@]}"; do
  if ! az containerapp show -g "$RG" -n "$app" -o json >"$tmp/$app.show.json"; then
    echo "::error::refusing registry cleanup; cannot read $app. Nothing was deleted." >&2
    exit 1
  fi
  if ! az containerapp revision list -g "$RG" -n "$app" -o json >"$tmp/$app.revs.json"; then
    echo "::error::refusing registry cleanup; cannot list revisions of $app. Nothing was deleted." >&2
    exit 1
  fi
done

python3 "$ROOT/.github/scripts/retention.py" protected-tags "$tmp"/*.show.json "$tmp"/*.revs.json >"$tmp/protected.txt"
if [[ ! -s "$tmp/protected.txt" ]]; then
  echo "::error::refusing to delete tags; no deployed image tag was found" >&2
  exit 1
fi
echo "protected tags: $(tr '\n' ' ' <"$tmp/protected.txt")"

for repo in "${REPOS[@]}"; do
  if ! az acr repository show -n "$ACR_NAME" --repository "$repo" -o none 2>/dev/null; then
    echo "no repository $repo (nothing to prune)"
    continue
  fi
  az acr repository show-tags -n "$ACR_NAME" --repository "$repo" --orderby time_desc -o tsv >"$tmp/$repo.tags"
  mapfile -t doomed < <(python3 "$ROOT/.github/scripts/retention.py" delete-tags --keep 10 --protected "$tmp/protected.txt" <"$tmp/$repo.tags")
  for tag in "${doomed[@]}"; do
    [[ -n "$tag" ]] || continue
    [[ "$tag" =~ ^sha-[0-9a-f]{7,40}$ ]] || { echo "::error::refusing unexpected tag $tag" >&2; exit 1; }
    if grep -qx -- "$tag" "$tmp/protected.txt"; then
      echo "::error::refusing to delete protected tag $tag" >&2
      exit 1
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "would delete $repo:$tag"
    else
      echo "deleting $repo:$tag"
      az acr repository delete -n "$ACR_NAME" --image "${repo}:${tag}" --yes -o none
    fi
  done
done

for app in "${APPS[@]}"; do
  mapfile -t doomed_revs < <(python3 "$ROOT/.github/scripts/retention.py" deactivate-revisions --keep 3 <"$tmp/$app.revs.json")
  for rev in "${doomed_revs[@]}"; do
    [[ -n "$rev" ]] || continue
    [[ "$rev" =~ ^[a-z0-9.-]+$ ]] || { echo "::error::refusing revision name $rev" >&2; exit 1; }
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "would deactivate $app $rev"
    else
      echo "deactivating $app $rev"
      az containerapp revision deactivate -g "$RG" -n "$app" --revision "$rev" -o none
    fi
  done
done

echo "registry and revision cleanup done (dry_run=$DRY_RUN)"
