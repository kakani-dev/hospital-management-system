#!/usr/bin/env bash
# Local and CI self-check for the skip planner and the required-check reporter.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
dir="$root/.github/scripts"

bash "$dir/ci-plan.test.sh"
bash "$dir/ci-require-result.test.sh"
bash "$dir/ci-ok.test.sh"

hashes=$(bash "$dir/ci-input-hashes.sh")
for key in hash_web hash_api hash_database hash_prototype hash_e2e hash_mocked hash_deploy \
  hash_image_edge hash_image_identity hash_image_patients hash_image_scheduling hash_image_billing; do
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
grep -q 'pull-requests: read' "$ci"
grep -q 'cron: "17 4 \* \* \*"' "$ci"
grep -q 'ci-require-result.sh' "$ci"
grep -q 'ci-ok.sh' "$ci"

# deploy-aca.yml is main's pipeline (service_changes.py). A newer push may cancel
# a deploy that has not finished. workflow_dispatch must not be cancelled.
grep -q 'workflow_run:' "$deploy"
grep -q 'service_changes.py' "$deploy"
grep -Fq "cancel-in-progress: \${{ github.event_name != 'workflow_dispatch' }}" "$deploy"
if grep -q 'cancel-in-progress: false' "$deploy"; then
  echo "FAIL deploy-aca.yml must keep main's cancel-in-progress expression" >&2
  exit 1
fi

echo "ci-skip tests passed"
