#!/usr/bin/env bash
# Print one sha256 per CI job: hash_<job>=<64 hex>.
# Each hash is the git object ids of that job's inputs, plus the workflow and
# the skip planner. A failed job never reads this; the caller saves a pass
# marker only after success, keyed <job>-<hash>.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

entry() {
  local spec="$1"
  if git cat-file -e "HEAD:${spec}" 2>/dev/null; then
    printf '%s %s\n' "$spec" "$(git rev-parse "HEAD:${spec}")"
  else
    printf '%s missing\n' "$spec"
  fi
}

hash_of() {
  local name="$1"
  shift
  {
    entry ".github/workflows/ci.yml"
    entry ".github/scripts/ci-plan.sh"
    entry ".github/scripts/ci-input-hashes.sh"
    entry ".github/scripts/ci-require-result.sh"
    entry ".github/scripts/ci-ok.sh"
    entry ".github/actions/lookup-pass-marker/action.yml"
    entry ".github/actions/save-pass-marker/action.yml"
    local spec
    for spec in "$@"; do
      entry "$spec"
    done
  } | sha256sum | awk -v n="$name" '{print n"="$1}'
}

# Keep these path lists aligned with the filters in .github/workflows/ci.yml.
hash_of hash_web \
  apps/web \
  .editorconfig

hash_of hash_api \
  backend \
  supabase/migrations

hash_of hash_database \
  backend \
  supabase \
  .github/scripts/check-migration-versions.sh

hash_of hash_prototype \
  supabase \
  .github/supabase-ci \
  .github/scripts/supabase-ci-sql-tests.sh \
  .github/scripts/supabase-ci-hook-smoke.sh

hash_of hash_e2e \
  apps/web \
  backend \
  tests \
  scripts/dev \
  supabase \
  package.json \
  package-lock.json

hash_of hash_mocked \
  apps/web \
  backend \
  tests/playwright \
  package.json \
  package-lock.json \
  .github/scripts/detect-npm-script.sh

hash_of hash_deploy \
  infra/aca \
  .github/workflows/deploy-aca.yml \
  .github/workflows/cleanup.yml \
  .github/scripts/aca-rollout.sh \
  .github/scripts/aca-cleanup-azure.sh \
  .github/scripts/cleanup-github.sh \
  .github/scripts/service_changes.py \
  .github/scripts/retention.py \
  .github/scripts/test-deploy-plan.sh \
  scripts/smoke \
  scripts/azure-oidc-setup.sh \
  scripts/verify.sh \
  lefthook.yml \
  CONTRIBUTING.md \
  AGENTS.md \
  .cursor/rules/verify-before-commit.mdc \
  docs/deploy.md

hash_of hash_image_api \
  infra/docker \
  docker-compose.yml \
  .dockerignore \
  backend/gateway \
  backend/modules \
  backend/platform \
  backend/shared \
  backend/global.json \
  backend/Directory.Build.props \
  backend/Directory.Packages.props \
  backend/Hms.slnx

hash_of hash_image_edge \
  backend/edge \
  backend/platform \
  backend/shared \
  backend/global.json \
  backend/Directory.Build.props \
  backend/Directory.Packages.props \
  .dockerignore

hash_of hash_image_identity \
  backend/services/identity \
  backend/modules/Identity \
  backend/platform \
  backend/shared \
  backend/global.json \
  backend/Directory.Build.props \
  backend/Directory.Packages.props \
  .dockerignore

hash_of hash_image_patients \
  backend/services/patients \
  backend/modules/Patients \
  backend/platform \
  backend/shared \
  backend/global.json \
  backend/Directory.Build.props \
  backend/Directory.Packages.props \
  .dockerignore

hash_of hash_image_scheduling \
  backend/services/scheduling \
  backend/modules/Appointments \
  backend/platform \
  backend/shared \
  backend/global.json \
  backend/Directory.Build.props \
  backend/Directory.Packages.props \
  .dockerignore
