#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/ci-ok.sh"

expect_ok() {
  if ! NEEDS="$1" bash "$script" >/dev/null; then
    echo "FAIL expected ci-ok success: $1" >&2
    exit 1
  fi
}

expect_fail() {
  if NEEDS="$1" bash "$script" >/dev/null; then
    echo "FAIL expected ci-ok failure: $1" >&2
    exit 1
  fi
}

expect_ok '{"changes":{"result":"success"},"web":{"result":"success"},"web-run":{"result":"skipped"},"api-run":{"result":"success"}}'
expect_ok '{"changes":{"result":"success"},"db-supabase-prototype":{"result":"failure"},"web":{"result":"success"}}'
expect_ok '{"changes":{"result":"success"},"db-supabase-prototype":{"result":"cancelled"},"images":{"result":"skipped"}}'
expect_fail '{"changes":{"result":"failure"},"web":{"result":"skipped"}}'
expect_fail '{"changes":{"result":"success"},"images":{"result":"failure"}}'
expect_fail '{"changes":{"result":"success"},"e2e-run":{"result":"cancelled"}}'
expect_ok '{}'
if NEEDS='' bash "$script" >/dev/null 2>&1; then
  echo "FAIL empty NEEDS should fail" >&2
  exit 1
fi
echo "ci-ok tests passed"
