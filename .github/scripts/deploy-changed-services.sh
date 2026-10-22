#!/usr/bin/env bash
# Map changed paths to Azure Container Apps services.
# Stdin: one repo-relative path per line.
# Stdout: comma-separated subset of identity,patients,scheduling,edge
# (edge last), or empty when nothing deployable changed.
# Shared image inputs and deploy scripts select every service.
set -euo pipefail

identity=false
patients=false
scheduling=false
edge=false
all=false

while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  case "$path" in
    backend/platform/*|backend/shared/*|backend/global.json|backend/Directory.Build.props|backend/Directory.Packages.props|.dockerignore|infra/aca/*|.github/workflows/deploy-aca.yml|scripts/smoke/*|.github/scripts/deploy-changed-services.sh)
      all=true
      ;;
    backend/services/identity/*|backend/modules/Identity/*)
      identity=true
      ;;
    backend/services/patients/*|backend/modules/Patients/*)
      patients=true
      ;;
    backend/services/scheduling/*|backend/modules/Appointments/*)
      scheduling=true
      ;;
    backend/edge/*)
      edge=true
      ;;
  esac
done

if [ "$all" = true ]; then
  echo "identity,patients,scheduling,edge"
  exit 0
fi

out=()
[ "$identity" = true ] && out+=(identity)
[ "$patients" = true ] && out+=(patients)
[ "$scheduling" = true ] && out+=(scheduling)
[ "$edge" = true ] && out+=(edge)
if [ "${#out[@]}" -eq 0 ]; then
  exit 0
fi
IFS=,
echo "${out[*]}"
