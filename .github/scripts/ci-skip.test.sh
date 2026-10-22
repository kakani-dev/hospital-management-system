#!/usr/bin/env bash
# Local and CI self-check for the skip planner, required-check reporter, and deploy mapping.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
dir="$root/.github/scripts"

bash "$dir/ci-plan.test.sh"
bash "$dir/ci-require-result.test.sh"
bash "$dir/ci-ok.test.sh"
bash "$dir/deploy-changed-services.test.sh"

hashes=$(bash "$dir/ci-input-hashes.sh")
for key in hash_web hash_api hash_database hash_prototype hash_e2e hash_mocked hash_deploy \
  hash_image_api hash_image_edge hash_image_identity hash_image_patients hash_image_scheduling; do
  if ! printf '%s\n' "$hashes" | grep -Eq "^${key}=[0-9a-f]{64}$"; then
    echo "FAIL missing or bad $key" >&2
    printf '%s\n' "$hashes" >&2
    exit 1
  fi
done
echo "input hashes ok"

ci="$root/.github/workflows/ci.yml"
deploy="$root/.github/workflows/deploy-aca.yml"

count_name() {
  local name="$1"
  grep -c "^    name: ${name}$" "$ci"
}

for required in \
  "Frontend (lint, unit tests, build)" \
  "Backend (build + unit tests)" \
  "SQL/RLS tests + API integration tests (real Postgres)" \
  "Playwright E2E (web + API + mock auth + Postgres)"; do
  n=$(count_name "$required")
  if [ "$n" -ne 1 ]; then
    echo "FAIL required check name [$required] appears $n times (want 1)" >&2
    exit 1
  fi
done

grep -q 'name: ci-ok$' "$ci"
grep -q 'dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d' "$ci"
grep -q 'cron: "17 4 \* \* \*"' "$ci"
grep -q 'ci-require-result.sh' "$ci"
grep -q 'ci-ok.sh' "$ci"

# Deploy rollouts must keep waiting; a newer push must not cancel one in progress.
n=$(grep -c 'cancel-in-progress: false' "$deploy")
if [ "$n" -ne 2 ]; then
  echo "FAIL deploy-aca cancel-in-progress: false count is $n (want 2)" >&2
  exit 1
fi

echo "ci-skip tests passed"
