#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/deploy-changed-services.sh"

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: got [$got] want [$want]" >&2
    exit 1
  fi
}

map_paths() {
  printf '%s\n' "$@" | bash "$script"
}

expect_eq "frontend" "$(map_paths apps/web/src/App.tsx)" ""
expect_eq "migration" "$(map_paths supabase/migrations/20261022120000_example.sql)" ""
expect_eq "docs" "$(map_paths docs/architecture/microservices.md)" ""
expect_eq "gateway" "$(map_paths backend/gateway/Hms.Gateway/Program.cs)" ""
expect_eq "unit test" "$(map_paths backend/tests/Hms.UnitTests/Foo.cs)" ""
expect_eq "identity" "$(map_paths backend/services/identity/Hms.Identity.Api/Program.cs)" "identity"
expect_eq "identity module" "$(map_paths backend/modules/Identity/Hms.Modules.Identity/Member.cs)" "identity"
expect_eq "patients+edge" "$(map_paths backend/modules/Patients/Hms.Modules.Patients/Patient.cs backend/edge/Hms.Edge/Program.cs)" "patients,edge"
expect_eq "scheduling" "$(map_paths backend/services/scheduling/Hms.Scheduling.Api/Program.cs)" "scheduling"
expect_eq "platform" "$(map_paths backend/platform/Hms.Platform/Health.cs)" "identity,patients,scheduling,edge"
expect_eq "shared kernel" "$(map_paths backend/shared/Hms.SharedKernel/Tenant.cs)" "identity,patients,scheduling,edge"
expect_eq "props" "$(map_paths backend/Directory.Packages.props)" "identity,patients,scheduling,edge"
expect_eq "deploy script" "$(map_paths infra/aca/deploy-aca.sh)" "identity,patients,scheduling,edge"
expect_eq "smoke" "$(map_paths scripts/smoke/smoke-gateway.sh)" "identity,patients,scheduling,edge"
expect_eq "dockerignore" "$(map_paths .dockerignore)" "identity,patients,scheduling,edge"
expect_eq "identity wins over none" "$(map_paths apps/web/src/App.tsx backend/services/identity/Dockerfile)" "identity"
echo "deploy-changed-services tests passed"
