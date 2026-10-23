#!/usr/bin/env bash
# Turn path-filter flags and pass-cache hits into run/skip decisions.
# Stdout is KEY=value lines for $GITHUB_OUTPUT. Diagnostics go to stderr.
# A full run (schedule, workflow_dispatch) ignores the pass cache.
set -euo pipefail

is_true() { [ "${1:-}" = "true" ]; }

or_flag() {
  local value
  for value in "$@"; do
    if is_true "$value"; then
      echo true
      return
    fi
  done
  echo false
}

# $1 affected (true/false), $2 cached (true/false)
decide() {
  if is_true "${FULL:-}"; then
    echo true
    return
  fi
  if is_true "$1" && ! is_true "$2"; then
    echo true
  else
    echo false
  fi
}

web_affected=$(or_flag "${SHARED:-}" "${FRONTEND:-}")
api_affected=$(or_flag "${SHARED:-}" "${BACKEND:-}" "${MIGRATIONS:-}")
database_affected=$(or_flag "${SHARED:-}" "${BACKEND:-}" "${SQL:-}" "${MIGRATIONS:-}")
prototype_affected=$(or_flag "${SHARED:-}" "${SQL:-}" "${MIGRATIONS:-}")
e2e_affected=$(or_flag "${SHARED:-}" "${FRONTEND:-}" "${BACKEND:-}" "${PLAYWRIGHT:-}")
mocked_affected=$(or_flag "${SHARED:-}" "${FRONTEND:-}" "${BACKEND:-}" "${PLAYWRIGHT:-}")
deploy_affected=$(or_flag "${SHARED:-}" "${DEPLOY:-}")
image_edge_affected=$(or_flag "${SHARED:-}" "${IMAGE_EDGE:-}")
image_identity_affected=$(or_flag "${SHARED:-}" "${IMAGE_IDENTITY:-}")
image_patients_affected=$(or_flag "${SHARED:-}" "${IMAGE_PATIENTS:-}")
image_scheduling_affected=$(or_flag "${SHARED:-}" "${IMAGE_SCHEDULING:-}")
image_billing_affected=$(or_flag "${SHARED:-}" "${IMAGE_BILLING:-}")
image_inventory_affected=$(or_flag "${SHARED:-}" "${IMAGE_INVENTORY:-}")

run_web=$(decide "$web_affected" "${CACHED_WEB:-}")
run_api=$(decide "$api_affected" "${CACHED_API:-}")
run_database=$(decide "$database_affected" "${CACHED_DATABASE:-}")
run_prototype=$(decide "$prototype_affected" "${CACHED_PROTOTYPE:-}")
run_e2e=$(decide "$e2e_affected" "${CACHED_E2E:-}")
run_mocked=$(decide "$mocked_affected" "${CACHED_MOCKED:-}")
run_deploy=$(decide "$deploy_affected" "${CACHED_DEPLOY:-}")
run_image_edge=$(decide "$image_edge_affected" "${CACHED_IMAGE_EDGE:-}")
run_image_identity=$(decide "$image_identity_affected" "${CACHED_IMAGE_IDENTITY:-}")
run_image_patients=$(decide "$image_patients_affected" "${CACHED_IMAGE_PATIENTS:-}")
run_image_scheduling=$(decide "$image_scheduling_affected" "${CACHED_IMAGE_SCHEDULING:-}")
run_image_billing=$(decide "$image_billing_affected" "${CACHED_IMAGE_BILLING:-}")
run_image_inventory=$(decide "$image_inventory_affected" "${CACHED_IMAGE_INVENTORY:-}")

images_json='{"include":['
images_sep=''
images_count=0
append_image() {
  local run="$1" name="$2" dockerfile="$3" input_hash="$4" cache_job="$5"
  is_true "$run" || return 0
  images_json+="${images_sep}{\"name\":\"${name}\",\"dockerfile\":\"${dockerfile}\",\"input_hash\":\"${input_hash}\",\"cache_job\":\"${cache_job}\"}"
  images_sep=','
  images_count=$((images_count + 1))
}
append_image "$run_image_edge" edge backend/edge/Dockerfile "${HASH_IMAGE_EDGE:-}" images-edge
append_image "$run_image_identity" identity backend/services/identity/Dockerfile "${HASH_IMAGE_IDENTITY:-}" images-identity
append_image "$run_image_patients" patients backend/services/patients/Dockerfile "${HASH_IMAGE_PATIENTS:-}" images-patients
append_image "$run_image_scheduling" scheduling backend/services/scheduling/Dockerfile "${HASH_IMAGE_SCHEDULING:-}" images-scheduling
append_image "$run_image_billing" billing backend/services/billing/Dockerfile "${HASH_IMAGE_BILLING:-}" images-billing
append_image "$run_image_inventory" inventory backend/services/inventory/Dockerfile "${HASH_IMAGE_INVENTORY:-}" images-inventory
images_json+=']}'

if [ "$images_count" -eq 0 ]; then
  # Non-empty so a skipped images job still has a parseable matrix.
  images_any=false
  images_json='{"include":[{"name":"edge","dockerfile":"backend/edge/Dockerfile","input_hash":"skipped","cache_job":"images-edge"}]}'
else
  images_any=true
fi

{
  echo "run_web=${run_web}"
  echo "run_api=${run_api}"
  echo "run_database=${run_database}"
  echo "run_prototype=${run_prototype}"
  echo "run_e2e=${run_e2e}"
  echo "run_mocked=${run_mocked}"
  echo "run_deploy=${run_deploy}"
  echo "images_any=${images_any}"
  echo "images_matrix=${images_json}"
}

{
  echo "CI plan full=${FULL:-false}"
  echo "  web        affected=${web_affected} cached=${CACHED_WEB:-false} run=${run_web}"
  echo "  api        affected=${api_affected} cached=${CACHED_API:-false} run=${run_api}"
  echo "  database   affected=${database_affected} cached=${CACHED_DATABASE:-false} run=${run_database}"
  echo "  prototype  affected=${prototype_affected} cached=${CACHED_PROTOTYPE:-false} run=${run_prototype}"
  echo "  e2e        affected=${e2e_affected} cached=${CACHED_E2E:-false} run=${run_e2e}"
  echo "  mocked     affected=${mocked_affected} cached=${CACHED_MOCKED:-false} run=${run_mocked}"
  echo "  deploy     affected=${deploy_affected} cached=${CACHED_DEPLOY:-false} run=${run_deploy}"
  echo "  image edge=${run_image_edge} identity=${run_image_identity} patients=${run_image_patients} scheduling=${run_image_scheduling} billing=${run_image_billing} inventory=${run_image_inventory}"
} >&2

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### CI skip plan"
    echo ""
    echo "| Heavy job | Runs |"
    echo "|---|---|"
    echo "| Frontend | ${run_web} |"
    echo "| Backend | ${run_api} |"
    echo "| SQL/RLS + API integration | ${run_database} |"
    echo "| DB prototype | ${run_prototype} |"
    echo "| Playwright E2E | ${run_e2e} |"
    echo "| Web E2E mocked | ${run_mocked} |"
    echo "| Deploy scripts | ${run_deploy} |"
    echo "| Images | ${images_any} |"
    echo ""
    if is_true "${FULL:-}"; then
      echo "Full run (schedule or workflow_dispatch): pass cache ignored."
    else
      echo "Pass cache skips a job whose inputs already succeeded. A failed job has no marker, so it reruns."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
