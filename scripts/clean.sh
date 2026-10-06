#!/usr/bin/env bash
# Removes local build/test artifacts for the web app, Playwright and the .NET backend.
#   scripts/clean.sh         # build + test outputs only
#   scripts/clean.sh --all   # also node_modules (re-run `npm ci` / `npm run web:install` afterwards)
# Safe to run repeatedly; only deletes git-ignored, regenerable paths inside this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ALL=false
for arg in "$@"; do
  case "$arg" in
    --all) ALL=true ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

removed=0
rm_path() {
  local p
  for p in "$@"; do
    if [[ -e "$p" ]]; then
      rm -rf -- "$p"
      echo "  removed ${p#"$ROOT"/}"
      removed=$((removed + 1))
    fi
  done
}

echo "==> Web (apps/web)"
rm_path apps/web/dist apps/web/coverage apps/web/.vite apps/web/node_modules/.vite apps/web/node_modules/.vitest
while IFS= read -r -d '' f; do rm_path "$f"; done < <(find . -name '*.tsbuildinfo' -not -path '*/node_modules/*' -print0)

echo "==> Playwright"
rm_path tests/playwright/test-results tests/playwright/playwright-report tests/playwright/blob-report \
        test-results playwright-report blob-report

echo "==> Backend (.NET)"
if command -v dotnet >/dev/null 2>&1; then
  dotnet clean backend/Hms.slnx --nologo --verbosity quiet >/dev/null 2>&1 \
    && echo "  dotnet clean backend/Hms.slnx" \
    || echo "  dotnet clean failed (continuing with directory removal)"
else
  echo "  dotnet not on PATH; removing bin/obj directories only"
fi
while IFS= read -r -d '' d; do rm_path "$d"; done < <(find backend \( -name bin -o -name obj -o -name TestResults \) -type d -prune -print0)

if [[ "$ALL" == true ]]; then
  echo "==> node_modules (--all)"
  rm_path node_modules apps/web/node_modules
fi

echo "==> Done (${removed} paths removed)"
