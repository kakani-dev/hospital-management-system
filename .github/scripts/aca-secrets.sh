#!/usr/bin/env bash
# Container Apps secrets from GitHub Actions secrets (issue #68).
# Sourced by aca-rollout.sh. Run directly only for: aca-secrets.sh names [mode]
# The manifest (.github/aca-secrets.tsv) maps app secret -> GitHub secret -> env var.
# Values arrive as env vars named after the GitHub secret; they are masked, compared
# by hash, never echoed, and only written when they differ from the live value.

ACA_SECRETS_MANIFEST="${ACA_SECRETS_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/aca-secrets.tsv}"
declare -gA ACA_SECRET_OLD=()   # "app<TAB>secret" -> previous value, in memory only
declare -ga ACA_SECRET_ENV=()   # Name=secretref:secret for the current app

aca_secrets_mode() {
  case "${ACA_SECRETS_SOURCE:-legacy}" in
    legacy|github) printf '%s\n' "${ACA_SECRETS_SOURCE:-legacy}" ;;
    *) echo "ACA_SECRETS_SOURCE must be legacy or github, got '${ACA_SECRETS_SOURCE}'" >&2; return 1 ;;
  esac
}

# Rows for one service (or all with "*") active in the current mode.
aca_secret_rows() {
  local want="$1" mode
  mode="$(aca_secrets_mode)" || return 1
  [[ -r "$ACA_SECRETS_MANIFEST" ]] || { echo "missing $ACA_SECRETS_MANIFEST" >&2; return 1; }
  awk -F'\t' -v s="$want" -v m="$mode" '
    /^#/ || NF == 0 { next }
    NF != 5 { printf "bad manifest line %d\n", NR > "/dev/stderr"; exit 3 }
    (s == "*" || $1 == s) && ($5 == "legacy" || m == "github") { print }
  ' "$ACA_SECRETS_MANIFEST"
}

# GitHub secret names the current mode needs, sorted, one per line.
aca_secret_names() { aca_secret_rows "*" | cut -f3 | sort -u; }

# Mask every value and fail closed (names only) if any needed one is empty.
aca_secrets_require() {
  local svc name missing=()
  for svc in "$@"; do
    while IFS=$'\t' read -r _ _ name _ _; do
      if [[ -z "${!name:-}" ]]; then
        [[ " ${missing[*]} " == *" $name "* ]] || missing+=("$name")
      else
        echo "::add-mask::${!name}"
      fi
    done < <(aca_secret_rows "$svc")
  done
  if ((${#missing[@]})); then
    echo "::error::GitHub secret(s) missing or empty: ${missing[*]}. No container app was changed." >&2
    return 1
  fi
}

_aca_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# Live value of one app secret; empty when the secret does not exist yet.
_aca_live() {
  az containerapp secret show -g "$RG" -n "$1" --secret-name "$2" --query value -o tsv 2>/dev/null || true
}

# A GitHub secret shared by several apps (HMS_EDGE_KEY) may only change when every
# app using it is in this rollout, or callers and callees would disagree.
aca_secrets_guard_shared() {
  local -a rolling=("$@")
  local name users svc aca live
  while read -r name; do
    users="$(aca_secret_rows "*" | awk -F'\t' -v n="$name" '$3 == n { print $1 "\t" $2 }')"
    (( $(wc -l <<<"$users") > 1 )) || continue
    local outside=0 changed=0
    while IFS=$'\t' read -r svc aca; do
      [[ " ${rolling[*]} " == *" $svc "* ]] || outside=1
      live="$(_aca_live "ca-hms-$svc" "$aca")"
      [[ "$(_aca_hash "$live")" == "$(_aca_hash "${!name}")" ]] || changed=1
    done <<<"$users"
    if ((changed && outside)); then
      echo "::error::$name differs from the live value but not every app using it is in this rollout. Run deploy-aca with the current tag and a blank service to roll all apps. No container app was changed." >&2
      return 1
    fi
  done < <(aca_secret_names)
}

# Write changed secrets for one app, keep old values in memory for rollback, and fill
# ACA_SECRET_ENV with the secretref env args for the next revision.
aca_secrets_apply() {
  local service="$1" app="ca-hms-$1" aca name env before after live
  local -a pairs=()
  ACA_SECRET_ENV=()
  while IFS=$'\t' read -r _ aca name env _; do
    ACA_SECRET_ENV+=("${env}=secretref:${aca}")
    live="$(_aca_live "$app" "$aca")"
    [[ "$(_aca_hash "$live")" == "$(_aca_hash "${!name}")" ]] && continue
    ACA_SECRET_OLD["$app"$'\t'"$aca"]="$live"
    pairs+=("${aca}=${!name}")
  done < <(aca_secret_rows "$service")
  ((${#pairs[@]})) || { echo "   $app secrets already match GitHub"; return 0; }
  before="$(az containerapp secret list -g "$RG" -n "$app" --query "[].name" -o tsv | sort)"
  az_retry containerapp secret set -g "$RG" -n "$app" --secrets "${pairs[@]}" -o none
  after="$(az containerapp secret list -g "$RG" -n "$app" --query "[].name" -o tsv | sort)"
  local n
  for n in $before; do
    grep -qx "$n" <<<"$after" || die "$app lost secret $n after secret set"
  done
  echo "   $app updated ${#pairs[@]} secret(s) from GitHub (names: ${pairs[*]%%=*})"
}

# Put back secrets this process changed. Only previous values that existed are restored.
aca_secrets_restore() {
  local key app aca rc=0
  for key in "${!ACA_SECRET_OLD[@]}"; do
    app="${key%%$'\t'*}"; aca="${key#*$'\t'}"
    [[ -n "${ACA_SECRET_OLD[$key]}" ]] || { echo "::warning::$app $aca was new; left in place" >&2; continue; }
    echo "restoring $app secret $aca"
    az_retry containerapp secret set -g "$RG" -n "$app" --secrets "${aca}=${ACA_SECRET_OLD[$key]}" -o none || rc=1
  done
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    names) ACA_SECRETS_SOURCE="${2:-${ACA_SECRETS_SOURCE:-legacy}}" aca_secret_names ;;
    *) echo "usage: $0 names [legacy|github]" >&2; exit 2 ;;
  esac
fi
