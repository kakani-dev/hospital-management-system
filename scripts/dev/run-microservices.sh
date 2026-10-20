#!/usr/bin/env bash
# Runs the microservices stack locally WITHOUT Docker: identity, patients and scheduling on
# internal ports plus the YARP edge (the single public base URL) on API_PORT.
# Used by Playwright (tests/playwright/playwright.config.ts) and for local development.
#
# Env (all optional):
#   API_PORT            edge port (default 8080)
#   HMS_MS_PORT_BASE    internal ports are base+1..3 (default 8100)
#   HMS_MS_DB           base connection string WITHOUT credentials
#                       (default Host=localhost;Port=5432;Database=hms)
#   HMS_MS_EDGE_KEY     shared edge->service key (default: random per run)
#   HMS_MS_NO_BUILD=1   skip `dotnet build` (CI builds once beforehand)
#   HMS_MS_CONFIGURATION Debug|Release (default Debug)
# Everything else (Auth__Supabase__ProjectUrl, Auth__Supabase__AllowInsecureHttp,
# ASPNETCORE_ENVIRONMENT, RateLimiting__*, Serilog__*) is inherited by every process.
# Each service logs in with its own local-only role (supabase/scripts/local-api-login-role.sql).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND="$ROOT/backend"
API_PORT="${API_PORT:-8080}"
# Internal service ports (identity, patients, scheduling) = base+1..3; override to run two stacks side by side.
PORT_BASE="${HMS_MS_PORT_BASE:-8100}"
ID_PORT=$((PORT_BASE + 1)) PAT_PORT=$((PORT_BASE + 2)) SCH_PORT=$((PORT_BASE + 3))
DB="${HMS_MS_DB:-Host=localhost;Port=5432;Database=hms}"
CONFIG="${HMS_MS_CONFIGURATION:-Debug}"
EDGE_KEY="${HMS_MS_EDGE_KEY:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
# The edge owns the public URL; never let a parent's ASPNETCORE_URLS leak into the services.
unset ASPNETCORE_URLS ConnectionStrings__HmsDatabase

if [ "${HMS_MS_NO_BUILD:-0}" != "1" ]; then
  dotnet build "$BACKEND/Hms.slnx" -c "$CONFIG" -v quiet -nologo
fi

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

start() { # name project-dir port [extra env...]
  local name="$1" dir="$BACKEND/$2" port="$3"; shift 3
  local dll; dll="$dir/bin/$CONFIG/net10.0/$(basename "$dir").dll"
  # exec so $! is the dotnet process itself (clean shutdown); cwd = content root for appsettings.
  ( cd "$dir" && exec env "$@" ASPNETCORE_URLS="http://localhost:$port" Edge__Key="$EDGE_KEY" dotnet "$dll" ) \
    > >(sed -u "s/^/[$name] /") 2>&1 &
  pids+=("$!")
}

login() { echo "$DB;Username=hms_$1_login;Password=hms_$1_local_only"; }

start identity   services/identity/Hms.Identity.Api     "$ID_PORT" ConnectionStrings__HmsDatabase="$(login identity)"
start patients   services/patients/Hms.Patients.Api     "$PAT_PORT" ConnectionStrings__HmsDatabase="$(login patients)"
start scheduling services/scheduling/Hms.Scheduling.Api "$SCH_PORT" ConnectionStrings__HmsDatabase="$(login scheduling)" \
  Outbox__Dispatcher__Enabled="${HMS_MS_DISPATCHER:-false}"
start edge       edge/Hms.Edge                          "$API_PORT" \
  ReverseProxy__Clusters__identity__Destinations__primary__Address=http://localhost:$ID_PORT/ \
  ReverseProxy__Clusters__patients__Destinations__primary__Address=http://localhost:$PAT_PORT/ \
  ReverseProxy__Clusters__scheduling__Destinations__primary__Address=http://localhost:$SCH_PORT/

echo "edge: http://localhost:$API_PORT (ready: /health/ready)"
# Exit (and tear everything down) as soon as any process dies.
wait -n
echo "a microservice process exited; stopping the stack" >&2
exit 1
