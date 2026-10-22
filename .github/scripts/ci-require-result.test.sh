#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/ci-require-result.sh"

expect_ok() {
  if ! bash "$script" "$1" "$2" >/dev/null; then
    echo "FAIL expected success: changes=$1 work=$2" >&2
    exit 1
  fi
}

expect_fail() {
  if bash "$script" "$1" "$2" >/dev/null; then
    echo "FAIL expected failure: changes=$1 work=$2" >&2
    exit 1
  fi
}

expect_ok success success
expect_ok success skipped
expect_fail success failure
expect_fail success cancelled
expect_fail failure skipped
expect_fail failure success
expect_fail cancelled skipped
echo "ci-require-result tests passed"
