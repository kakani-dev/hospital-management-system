#!/usr/bin/env bash
# Reporter for a required check. Exit 0 when the heavy job succeeded or was
# skipped after a successful changes job. Exit 1 when changes or the work
# failed or was cancelled, so branch protection does not see a false green.
set -euo pipefail

changes="${1:?changes result}"
work="${2:?work result}"
echo "changes=${changes} work=${work}"

if [ "$changes" != "success" ]; then
  echo "::error::changes job is ${changes}; not reporting a green required check"
  exit 1
fi

case "$work" in
  success|skipped)
    echo "required check succeeds (work ${work})"
    exit 0
    ;;
  *)
    echo "::error::work job is ${work}"
    exit 1
    ;;
esac
