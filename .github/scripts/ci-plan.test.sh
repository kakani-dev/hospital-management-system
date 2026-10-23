#!/usr/bin/env bash
# Decision tests for which heavy jobs run.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
plan="$root/.github/scripts/ci-plan.sh"
fail=0

flags=(
  FULL SHARED FRONTEND BACKEND MIGRATIONS SQL PLAYWRIGHT DEPLOY
  IMAGE_EDGE IMAGE_IDENTITY IMAGE_PATIENTS IMAGE_SCHEDULING IMAGE_BILLING IMAGE_INVENTORY
  CACHED_WEB CACHED_API CACHED_DATABASE CACHED_PROTOTYPE CACHED_E2E CACHED_MOCKED CACHED_DEPLOY
  CACHED_IMAGE_EDGE CACHED_IMAGE_IDENTITY CACHED_IMAGE_PATIENTS CACHED_IMAGE_SCHEDULING CACHED_IMAGE_BILLING CACHED_IMAGE_INVENTORY
  HASH_IMAGE_EDGE HASH_IMAGE_IDENTITY HASH_IMAGE_PATIENTS HASH_IMAGE_SCHEDULING HASH_IMAGE_BILLING HASH_IMAGE_INVENTORY
)

clear_flags() {
  local name
  for name in "${flags[@]}"; do
    unset "$name" || true
  done
}

run_plan() {
  clear_flags
  export FULL=false SHARED=false FRONTEND=false BACKEND=false MIGRATIONS=false SQL=false
  export PLAYWRIGHT=false DEPLOY=false
  export IMAGE_EDGE=false IMAGE_IDENTITY=false IMAGE_PATIENTS=false IMAGE_SCHEDULING=false IMAGE_BILLING=false IMAGE_INVENTORY=false
  export CACHED_WEB=false CACHED_API=false CACHED_DATABASE=false CACHED_PROTOTYPE=false
  export CACHED_E2E=false CACHED_MOCKED=false CACHED_DEPLOY=false
  export CACHED_IMAGE_EDGE=false CACHED_IMAGE_IDENTITY=false
  export CACHED_IMAGE_PATIENTS=false CACHED_IMAGE_SCHEDULING=false CACHED_IMAGE_BILLING=false CACHED_IMAGE_INVENTORY=false
  export HASH_IMAGE_EDGE=bbb HASH_IMAGE_IDENTITY=ccc
  export HASH_IMAGE_PATIENTS=ddd HASH_IMAGE_SCHEDULING=eee HASH_IMAGE_BILLING=fff HASH_IMAGE_INVENTORY=ggg
  # shellcheck disable=SC1090
  eval "$1"
  bash "$plan" 2>/dev/null
}

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: got [$got] want [$want]" >&2
    fail=1
  fi
}

value() {
  local key="$1" text="$2"
  printf '%s\n' "$text" | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}'
}

check() {
  local label="$1" setup="$2" key="$3" want="$4"
  local out
  out=$(run_plan "$setup")
  expect_eq "$label $key" "$(value "$key" "$out")" "$want"
}

check "frontend-only" "export FRONTEND=true" run_web true
check "frontend-only" "export FRONTEND=true" run_api false
check "frontend-only" "export FRONTEND=true" run_database false
check "frontend-only" "export FRONTEND=true" run_prototype false
check "frontend-only" "export FRONTEND=true" run_e2e true
check "frontend-only" "export FRONTEND=true" run_mocked true
check "frontend-only" "export FRONTEND=true" run_deploy false
check "frontend-only" "export FRONTEND=true" images_any false

check "migration" "export MIGRATIONS=true SQL=true" run_web false
check "migration" "export MIGRATIONS=true SQL=true" run_api true
check "migration" "export MIGRATIONS=true SQL=true" run_database true
check "migration" "export MIGRATIONS=true SQL=true" run_prototype true
check "migration" "export MIGRATIONS=true SQL=true" run_e2e false
check "migration" "export MIGRATIONS=true SQL=true" run_mocked false
check "migration" "export MIGRATIONS=true SQL=true" images_any false

check "sql-tests-only" "export SQL=true" run_api false
check "sql-tests-only" "export SQL=true" run_database true
check "sql-tests-only" "export SQL=true" run_prototype true
check "sql-tests-only" "export SQL=true" run_e2e false

check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" run_api true
check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" run_database true
check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" run_e2e true
check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" run_mocked true
check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" run_web false
check "backend-service" "export BACKEND=true IMAGE_IDENTITY=true" images_any true

identity_out=$(run_plan "export BACKEND=true IMAGE_IDENTITY=true")
identity_matrix=$(value images_matrix "$identity_out")
printf '%s' "$identity_matrix" | grep -q '"name":"identity"' || { echo "FAIL identity matrix missing identity" >&2; fail=1; }
printf '%s' "$identity_matrix" | grep -q '"name":"api"' && { echo "FAIL identity matrix included api" >&2; fail=1; }
empty_matrix=$(value images_matrix "$(run_plan "")")
printf '%s' "$empty_matrix" | grep -q '"name":"edge"' || { echo "FAIL empty image matrix fallback is not edge" >&2; fail=1; }
printf '%s' "$empty_matrix" | grep -q '"name":"api"' && { echo "FAIL empty image matrix fallback included api" >&2; fail=1; }
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$identity_matrix"

check "passed-web-skipped" "export FRONTEND=true CACHED_WEB=true" run_web false
check "passed-web-skipped" "export FRONTEND=true CACHED_WEB=true" run_e2e true
check "failed-api-reruns" "export BACKEND=true CACHED_API=false CACHED_WEB=true" run_api true

check "shared-all-cached" "export SHARED=true CACHED_WEB=true CACHED_API=true CACHED_DATABASE=true CACHED_PROTOTYPE=true CACHED_E2E=true CACHED_MOCKED=true CACHED_DEPLOY=true CACHED_IMAGE_EDGE=true CACHED_IMAGE_IDENTITY=true CACHED_IMAGE_PATIENTS=true CACHED_IMAGE_SCHEDULING=true CACHED_IMAGE_BILLING=true CACHED_IMAGE_INVENTORY=true" run_web false
check "shared-all-cached" "export SHARED=true CACHED_WEB=true CACHED_API=true CACHED_DATABASE=true CACHED_PROTOTYPE=true CACHED_E2E=true CACHED_MOCKED=true CACHED_DEPLOY=true CACHED_IMAGE_EDGE=true CACHED_IMAGE_IDENTITY=true CACHED_IMAGE_PATIENTS=true CACHED_IMAGE_SCHEDULING=true CACHED_IMAGE_BILLING=true CACHED_IMAGE_INVENTORY=true" run_api false
check "shared-all-cached" "export SHARED=true CACHED_WEB=true CACHED_API=true CACHED_DATABASE=true CACHED_PROTOTYPE=true CACHED_E2E=true CACHED_MOCKED=true CACHED_DEPLOY=true CACHED_IMAGE_EDGE=true CACHED_IMAGE_IDENTITY=true CACHED_IMAGE_PATIENTS=true CACHED_IMAGE_SCHEDULING=true CACHED_IMAGE_BILLING=true CACHED_IMAGE_INVENTORY=true" images_any false

check "full-ignores-cache" "export FULL=true CACHED_WEB=true CACHED_API=true CACHED_DATABASE=true CACHED_PROTOTYPE=true CACHED_E2E=true CACHED_MOCKED=true CACHED_DEPLOY=true CACHED_IMAGE_EDGE=true" run_web true
check "full-ignores-cache" "export FULL=true CACHED_WEB=true CACHED_API=true" run_api true
check "full-ignores-cache" "export FULL=true CACHED_WEB=true" run_database true
check "full-ignores-cache" "export FULL=true CACHED_WEB=true" run_e2e true
check "full-ignores-cache" "export FULL=true CACHED_IMAGE_EDGE=true" images_any true

check "docs-only" "" run_web false
check "docs-only" "" run_api false
check "docs-only" "" run_e2e false
check "docs-only" "" images_any false

if [ "$fail" -ne 0 ]; then
  echo "ci-plan tests failed" >&2
  exit 1
fi
echo "ci-plan tests passed"
