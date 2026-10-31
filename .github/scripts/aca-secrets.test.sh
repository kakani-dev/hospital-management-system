#!/usr/bin/env bash
# Self-test for aca-secrets.sh (issue #68) against a fake az. No Azure, no real values.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# Fake az: secrets live in $WORK/az/<app>/<secret>; every call is logged by verb only.
mkdir -p "$WORK/bin" "$WORK/az"
cat >"$WORK/bin/az" <<'AZ'
#!/usr/bin/env bash
store="$FAKE_AZ"; app=""; sname=""; verb="$1 $2 $3"; shift 3
pairs=()
while (($#)); do
  case "$1" in
    -n) app="$2"; shift 2 ;;
    --secret-name) sname="$2"; shift 2 ;;
    --revision) echo "rev=$2" >>"$store.revlog"; shift 2 ;;
    --secrets) shift; while (($#)) && [[ "$1" != -* ]]; do pairs+=("$1"); shift; done ;;
    *) shift ;;
  esac
done
echo "$verb $app ${#pairs[@]}" >>"$store.log"
case "$verb" in
  "containerapp secret show") [[ -f "$store/$app/$sname" ]] || exit 3; cat "$store/$app/$sname"; echo ;;
  "containerapp secret list") ls "$store/$app" 2>/dev/null ;;
  "containerapp revision restart"|"containerapp revision activate") ;;
  "containerapp revision show") cat "$store/$app/.active" 2>/dev/null || echo true ;;
  "containerapp secret set") mkdir -p "$store/$app"; for p in "${pairs[@]}"; do printf '%s' "${p#*=}" >"$store/$app/${p%%=*}"; done ;;
  *) exit 9 ;;
esac
AZ
chmod +x "$WORK/bin/az"
export PATH="$WORK/bin:$PATH" FAKE_AZ="$WORK/az" RG=rg-test

seed() { mkdir -p "$WORK/az/$1"; printf '%s' "$3" >"$WORK/az/$1/$2"; }
for s in identity patients scheduling billing inventory privacy edge; do
  seed "ca-hms-$s" hms-edge-key "edge-old"
  [[ "$s" == edge ]] || seed "ca-hms-$s" hms-db "db-old-$s"
done
seed ca-hms-identity smtp-password "smtp-old"
seed ca-hms-identity supabase-service-role "supa-old"

run() { # run <mode> <bash snippet>  (fresh shell, library sourced)
  ACA_SECRETS_SOURCE="$1" bash -c '
    set -euo pipefail
    die() { echo "die: $*" >&2; exit 1; }
    az_retry() { az "$@"; }
    source "'"$HERE"'/aca-secrets.sh"
    '"$2"
}
set_all() {
  export SMTP_PASSWORD=smtp-old SUPABASE_SERVICE_ROLE_KEY=supa-old HMS_EDGE_KEY=edge-old
  for s in identity patients scheduling billing inventory privacy; do
    export "HMS_DB_${s^^}=db-old-$s"
  done
}

# 1. Manifest shape and names.
check "manifest rows have 5 fields and valid modes" \
  bash -c "awk -F'\t' '!/^#/ && NF { if (NF!=5 || (\$5!=\"legacy\" && \$5!=\"github\")) exit 1 }' '$ROOT/.github/aca-secrets.tsv'"
check "legacy mode needs only the identity mail pair" \
  test "$(bash "$HERE/aca-secrets.sh" names legacy | tr '\n' ' ')" = "SMTP_PASSWORD SUPABASE_SERVICE_ROLE_KEY "
check "github mode needs 9 names" test "$(bash "$HERE/aca-secrets.sh" names github | wc -l)" -eq 9
check "unknown mode is refused" bash -c "! ACA_SECRETS_SOURCE=vault bash '$HERE/aca-secrets.sh' names >/dev/null 2>&1"
missing_in_workflow=""
for n in $(bash "$HERE/aca-secrets.sh" names github); do
  grep -q "^ *$n: \${{ secrets.$n }}" "$ROOT/.github/workflows/deploy-aca.yml" || missing_in_workflow+=" $n"
done
# deploy-aca.yml wiring needs a token with workflow scope (see PR #68 patch). Until it
# lands, github mode fails closed at runtime on the empty values, so this is a warning.
if [[ -z "$missing_in_workflow" ]]; then ok "every manifest secret is passed by deploy-aca.yml"
else echo "::warning::deploy-aca.yml does not pass:$missing_in_workflow (ACA_SECRETS_SOURCE=github would refuse to deploy)"; fi
check "every service maps hms-edge-key and non-edge maps hms-db" bash -c "
  for s in identity patients scheduling billing inventory privacy edge; do
    grep -qP \"^\$s\thms-edge-key\t\" '$ROOT/.github/aca-secrets.tsv' || exit 1
    [[ \$s == edge ]] || grep -qP \"^\$s\thms-db\t\" '$ROOT/.github/aca-secrets.tsv' || exit 1
  done"

# 2. Fail closed on empty secrets, naming them without values.
set_all; unset HMS_DB_BILLING
out="$(run github 'aca_secrets_require billing edge' 2>&1 || true)"
check "missing secret is reported by name" grep -q "HMS_DB_BILLING" <<<"$out"
rc=0; run github 'aca_secrets_require billing' >/dev/null 2>&1 || rc=$?
check "missing secret check fails" test "$rc" -ne 0
check "no fake az write happened" test ! -e "$WORK/az.log"
set_all
out="$(run legacy 'aca_secrets_require patients')"
check "legacy patients needs no secrets" test -z "$out"
out="$(run github 'aca_secrets_require identity')"
check "present values are masked" test "$(grep -c '^::add-mask::' <<<"$out")" -eq 4

# 3. Apply writes only differences and builds secretref env args.
export HMS_DB_PATIENTS=db-new-patients
out="$(run github 'aca_secrets_apply patients; printf "%s\n" "${ACA_SECRET_ENV[@]}"' 2>&1)"
check "changed secret written" test "$(cat "$WORK/az/ca-hms-patients/hms-db")" = db-new-patients
check "unchanged secret kept" test "$(cat "$WORK/az/ca-hms-patients/hms-edge-key")" = edge-old
check "one secret set call with one pair" grep -q "containerapp secret set ca-hms-patients 1" "$WORK/az.log"
check "env args are secretrefs" bash -c "grep -qx 'ConnectionStrings__HmsDatabase=secretref:hms-db' <<<'$out' && grep -qx 'Edge__Key=secretref:hms-edge-key' <<<'$out'"
check "no value printed by apply" bash -c "! grep -q 'db-new-patients\|edge-old' <<<'$out'"
: >"$WORK/az.log"
run github 'aca_secrets_apply patients' >/dev/null
check "second apply is a no-op" bash -c "! grep -q 'secret set' '$WORK/az.log'"
out="$(run legacy 'aca_secrets_apply identity; printf "%s\n" "${ACA_SECRET_ENV[@]}"')"
check "legacy identity only maps the mail pair" test "$(grep -c secretref <<<"$out")" -eq 2
check "legacy never touches identity hms-db" test "$(cat "$WORK/az/ca-hms-identity/hms-db")" = db-old-identity

# 4. Rollback restores the previous value written by this process.
export HMS_DB_BILLING=db-bad
run github 'aca_secrets_apply billing >/dev/null; aca_secrets_restore >/dev/null'
check "restore puts back the old value" test "$(cat "$WORK/az/ca-hms-billing/hms-db")" = db-old-billing
set_all; export HMS_DB_PATIENTS=db-new-patients

# 5. Shared HMS_EDGE_KEY may only change when every app rolls.
check "unchanged shared key passes on partial rollout" run github 'aca_secrets_guard_shared patients'
export HMS_EDGE_KEY=edge-new
rc=0; run github 'aca_secrets_guard_shared patients' >/dev/null 2>&1 || rc=$?
check "changed shared key refused on partial rollout" test "$rc" -ne 0
check "changed shared key allowed on full rollout" \
  run github 'aca_secrets_guard_shared identity patients scheduling billing inventory privacy edge'

# 6. Reused revision (#256): sync secrets, restart only when a value changed.
set_all; for s in identity patients scheduling billing inventory privacy; do seed "ca-hms-$s" hms-db "db-old-$s"; seed "ca-hms-$s" hms-edge-key edge-old; done
seed ca-hms-edge hms-edge-key edge-old
: >"$WORK/az.log"
out="$(run github 'aca_secrets_sync_reused patients ca-hms-patients--s-abc' 2>&1)"
check "reuse with equal values says already match" grep -q "ca-hms-patients secrets already match GitHub" <<<"$out"
check "reuse with equal values writes nothing" bash -c "! grep -q 'secret set' '$WORK/az.log'"
check "reuse with equal values does not restart" bash -c "! grep -q 'revision restart' '$WORK/az.log'"
export HMS_DB_PATIENTS=db-rotated
: >"$WORK/az.log"
out="$(run github 'aca_secrets_sync_reused patients ca-hms-patients--s-abc; echo "changed=$ACA_SECRETS_CHANGED"' 2>&1)"
check "reuse with a changed value writes it" test "$(cat "$WORK/az/ca-hms-patients/hms-db")" = db-rotated
check "reuse with a changed value counts one change" grep -qx "changed=1" <<<"$out"
check "reuse with a changed value restarts the revision once" test "$(grep -c 'revision restart ca-hms-patients' "$WORK/az.log")" -eq 1
check "no value printed on reuse" bash -c "! grep -q 'db-rotated\|db-old' <<<'$out'"
seed ca-hms-patients hms-db db-old-patients
: >"$WORK/az.log"
run github 'aca_secrets_sync_reused patients ca-hms-patients--s-abc >/dev/null; aca_secrets_restore >/dev/null'
check "rollback after reuse restores the old value" test "$(cat "$WORK/az/ca-hms-patients/hms-db")" = db-old-patients
check "rollback after reuse restarts the revision again" test "$(grep -c 'revision restart ca-hms-patients' "$WORK/az.log")" -eq 2
set_all
: >"$WORK/az.log"
run legacy 'aca_secrets_sync_reused patients ca-hms-patients--s-abc' >/dev/null
check "legacy reuse of a non-identity app touches nothing" bash -c "! grep -q 'secret set\|revision restart' '$WORK/az.log'"
check "rollout calls the reuse sync" grep -q 'aca_secrets_sync_reused "\$service" "\$new"' "$HERE/aca-rollout.sh"

# Issue #263: a reused revision gets fresh replicas before the readiness wait.
set_all
: >"$WORK/az.log"
run legacy 'aca_refresh_reused patients ca-hms-patients--s-new ca-hms-patients--s-old' >/dev/null
check "reused active revision is restarted even with no secret change" test "$(grep -c 'revision restart ca-hms-patients' "$WORK/az.log")" -eq 1
echo false >"$WORK/az/ca-hms-identity/.active"; : >"$WORK/az.log"
run legacy 'aca_refresh_reused identity ca-hms-identity--s-new ca-hms-identity--s-old' >/dev/null
check "reused inactive revision is activated, not restarted" bash -c "grep -q 'revision activate ca-hms-identity' '$WORK/az.log' && ! grep -q 'revision restart' '$WORK/az.log'"
rm -f "$WORK/az/ca-hms-identity/.active"; : >"$WORK/az.log"
run legacy 'aca_refresh_reused billing ca-hms-billing--s-same ca-hms-billing--s-same' >/dev/null
check "serving revision is not restarted" bash -c "! grep -q 'revision' '$WORK/az.log'"
: >"$WORK/az.log"
run legacy 'ACA_RESTARTED+=("ca-hms-billing"$'"'"'\t'"'"'"ca-hms-billing--s-new"); aca_refresh_reused billing ca-hms-billing--s-new ca-hms-billing--s-old' >/dev/null
check "revision already restarted by the secret sync is not restarted twice" bash -c "! grep -q 'revision' '$WORK/az.log'"
check "rollout refreshes a reused revision before the wait" grep -q 'aca_refresh_reused "\$service" "\$new" "\$prev"' "$HERE/aca-rollout.sh"

echo "---"; ((fails == 0)) && echo "aca-secrets: all checks passed" || { echo "aca-secrets: $fails failed"; exit 1; }
