#!/usr/bin/env bash
# Print the image tag that is serving traffic on each MediCore container app.
# One line per service: "<service>\t<tag>". The plan uses this to rebuild an app
# whose running tag is not the tag main would build.
#
# A revision with traffic wins. If nothing has traffic, the app template image is used.
# An unreadable app fails the script. The plan must not guess and skip a stale service.
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-medicore-hms-dev}"
if [[ "$RG" != "rg-medicore-hms-dev" ]]; then
  echo "::error::refusing resource group $RG" >&2
  exit 1
fi

tag_of() {
  local image="$1" app="$2" tag
  [[ -n "$image" && "$image" == *:* ]] || {
    echo "::error::$app has no image tag (got '${image:-empty}')" >&2
    exit 1
  }
  tag="${image##*:}"
  [[ -n "$tag" && "$tag" != "$image" ]] || {
    echo "::error::$app image tag could not be read from $image" >&2
    exit 1
  }
  printf '%s' "$tag"
}

for service in identity patients scheduling billing edge; do
  app="ca-hms-$service"
  rev="$(az containerapp ingress traffic show -g "$RG" -n "$app" -o json | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if (r.get("weight") or 0) > 0]
rows.sort(key=lambda r: r.get("weight") or 0, reverse=True)
print((rows[0].get("revisionName") or "") if rows else "")
')"
  if [[ -n "$rev" ]]; then
    image="$(az containerapp revision show -g "$RG" -n "$app" --revision "$rev" \
      --query "properties.template.containers[0].image" -o tsv)"
  else
    image="$(az containerapp show -g "$RG" -n "$app" \
      --query "properties.template.containers[0].image" -o tsv)"
  fi
  printf '%s\t%s\n' "$service" "$(tag_of "$image" "$app")"
done
