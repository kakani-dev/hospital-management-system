#!/usr/bin/env bash
# Decide whether a main push should deploy the Vercel web app.
# Stdout is deploy=true or deploy=false, for $GITHUB_OUTPUT.
#
# A push deploys when it touches the Vite app (apps/web), the shared Vercel
# config (infra/vercel), or this deploy workflow. Other commits (API, SQL,
# docs) do not. workflow_dispatch passes --force and always deploys.
#
# Usage: web-deploy-plan.sh [--force] [changed-files]
# changed-files is a newline-separated list. Omit it to read stdin.
set -euo pipefail

if [[ "${1:-}" == "--force" ]]; then
  echo "deploy=true"
  exit 0
fi

file="${1:-}"
deploy=false
if [[ -n "$file" ]]; then
  input="$(cat "$file")"
else
  input="$(cat)"
fi

while IFS= read -r path || [[ -n "$path" ]]; do
  path="${path//$'\r'/}"
  [[ -z "$path" ]] && continue
  case "$path" in
    apps/web|apps/web/*|infra/vercel|infra/vercel/*|.github/workflows/deploy-web.yml)
      deploy=true
      ;;
  esac
done <<<"$input"

echo "deploy=${deploy}"
