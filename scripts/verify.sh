#!/usr/bin/env bash
# Fast local gate. Runs the same web and API unit checks as CI, and only the
# ones this change touches.
#
#   apps/web/**   npm run lint, npm run test, npm run build
#   backend/**    dotnet build + unit tests (Category!=Database)
#
# Anything else (docs, SQL, workflows) prints "none" and exits 0.
# The comparison is the branch against origin/main (or main), plus uncommitted
# and untracked files. VERIFY_PATHS (newline-separated) overrides that, which
# is how tests call --plan.
#
#   bash scripts/verify.sh          # run the selected checks
#   bash scripts/verify.sh --plan   # print web, api, or none, then exit
#
# Lefthook runs this on pre-push. Run it before every commit as well.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

plan_only=0
if [[ "${1:-}" == "--plan" ]]; then
  plan_only=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: bash scripts/verify.sh [--plan]" >&2
  exit 2
fi

collect_paths() {
  if [[ -n "${VERIFY_PATHS+x}" ]]; then
    printf '%s\n' "$VERIFY_PATHS"
    return
  fi
  local base=""
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="$(git merge-base HEAD origin/main)"
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    base="$(git merge-base HEAD main 2>/dev/null || true)"
  fi
  if [[ -n "$base" ]]; then
    git diff --name-only "$base" HEAD
  fi
  git diff --name-only
  git diff --name-only --cached
  git ls-files --others --exclude-standard
}

web=0
api=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    apps/web|apps/web/*) web=1 ;;
    backend|backend/*) api=1 ;;
  esac
done < <(collect_paths)

if [[ "$plan_only" == 1 ]]; then
  if [[ "$web" == 0 && "$api" == 0 ]]; then
    echo none
  else
    [[ "$web" == 1 ]] && echo web
    [[ "$api" == 1 ]] && echo api
  fi
  exit 0
fi

if [[ "$web" == 0 && "$api" == 0 ]]; then
  echo "verify: no apps/web or backend changes"
  exit 0
fi

if [[ "$web" == 1 ]]; then
  echo "verify: web lint, unit tests, build"
  if [[ ! -d apps/web/node_modules ]]; then
    npm ci --prefix apps/web --no-audit --no-fund
  fi
  npm --prefix apps/web run lint
  npm --prefix apps/web run test
  npm --prefix apps/web run build
fi

if [[ "$api" == 1 ]]; then
  echo "verify: dotnet build and unit tests"
  if ! command -v dotnet >/dev/null; then
    echo "dotnet is not installed" >&2
    exit 1
  fi
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
  dotnet build backend/Hms.slnx -c Release
  dotnet test backend/Hms.slnx -c Release --no-build --filter "Category!=Database"
fi
