#!/usr/bin/env bash
# Usage: detect-npm-script.sh <script-name> [required-file ...]
# Prints whether the ROOT package.json defines <script-name> and every required file exists,
# and writes present=true|false to $GITHUB_OUTPUT (when set). Always exits 0, so a job that
# is gated on it skips cleanly instead of failing when the feature hasn't been merged yet.
set -euo pipefail

name="${1:?script name}"
shift

present=true
if ! node -e 'const s = require("./package.json").scripts || {}; process.exit(s[process.argv[1]] ? 0 : 1)' "$name"; then
  present=false
  echo "::notice title=${name} not present::package.json has no \"${name}\" script on this ref; skipping (expected until it is merged)."
fi
for f in "$@"; do
  if [[ ! -e "$f" ]]; then
    present=false
    echo "::notice title=${name} not present::${f} is missing on this ref; skipping."
  fi
done
if [[ "$present" == "true" ]]; then
  echo "Found npm script \"${name}\": $(node -p 'require("./package.json").scripts[process.argv[1]]' "$name")"
fi

echo "present=${present}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "present=${present}" >> "$GITHUB_OUTPUT"
fi
