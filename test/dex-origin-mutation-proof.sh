#!/usr/bin/env bash
# dex-origin-mutation-proof.sh — prove test/terraform-dex-origin.bats can fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` that is dead under `set -e`, a `[ "$status" -ne 0 ]` that reads a
# MISSING FILE as "pattern absent", a mechanism assertion that passed vacuously
# because its own discovery returned empty. Every one of them was green.
#
# So: introduce each defect into the real file, confirm the EXPECTED test goes
# red, restore, confirm green again.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <dir>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Run: test/dex-origin-mutation-proof.sh

# Every mutation below is a sed expression, and sed expressions are
# single-quoted precisely SO THAT `$` stays literal — these patterns match shell
# variables in the source file, they do not expand them. Double-quoting as
# SC2016 suggests would expand `${DEX_ORIGIN_KEY}` against this harness's own
# environment, produce a pattern that matches nothing, and `mutate` would abort
# the run. File-scoped because a directive placed lower down binds only to the
# next command, which is how the first attempt at this silenced nothing.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB="scripts/lib/dex-origin.sh"
EXPOSE="scripts/lib/expose.sh"
DEX_MANIFEST="d2-signalloom/infra/inf-signalloom/base/dex.yaml"
SUITE="test/terraform-dex-origin.bats"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# An EXIT trap alone was the whole protection here, and it does not survive
# SIGKILL — which is what a tool timeout escalates to. A hard kill left three
# real files mutated, the &&-chained gate carried on into the next proof, and
# the leak was diagnosed as content lost in a merge. The helper adds the marker
# that outlives a hard kill, refuses to start on top of one, and verifies the
# restore on content AND mode. See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init dex-origin "$LIB" "$EXPOSE" "$DEX_MANIFEST"
trap ms_guard_on_exit EXIT

restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

# A sed that cannot silently do nothing — and that tells a sed SYNTAX ERROR
# apart from a pattern that no longer matches. Both used to read identically to
# "the mutation landed and the guard did not fire", which sends you off to fix a
# guard that is fine. md5 is gone with it; the rail hashes with sha256.
mutate() { ms_sed "$1" "$2"; }

# Runs the suite and reports the NAMES of the tests that failed.
#
# Names, not the `not ok <n>` numbers the first version used. Inserting two
# tests in the middle of the suite renumbered everything below them, so eleven
# expectations silently started pointing at the wrong test — a harness that
# reports "NOT PROVEN" for a guard that fired perfectly well is worse than no
# harness, because the natural response is to go and "fix" working code.
#
# A non-zero bats is the EXPECTED outcome here, and `set -o pipefail` at the top
# of this file promotes it to the pipeline's status — so without the `|| true`
# at the call site, `set -e` kills the harness on the first successful mutation
# and the run reports one line of output and exit 1. Observed on the first run
# of this file: it read as the mutation being rejected rather than as the
# harness being unable to survive its own success.
failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() {
  local label="$1" want="$2" got
  got="$(failing_tests || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore_all
}

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green before mutation" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"
echo ""

echo "=== mutations ==="

echo "M1  origin written to flux-system only (tenant copies dropped)"
mutate "$LIB" 's|^  for ns in "${ns_list\[@\]}"; do|  for ns in; do|'
check "M1 tenant-copy writes" "applying an origin patches every field that carries it"

echo "M2  lease copied into the tenant namespaces as well"
mutate "$LIB" 's|--type=merge -p "{\\"data\\":{\\"${DEX_ORIGIN_KEY}\\":\\"${origin}\\"}}" >/dev/null 2>&1 |--type=merge -p "{\\"data\\":{\\"${DEX_ORIGIN_KEY}\\":\\"${origin}\\",\\"${DEX_ORIGIN_KEY_METHOD}\\":\\"${method}\\"}}" >/dev/null 2>\&1 |'
check "M2 lease is single-homed" "applying an origin patches every field that carries it"

echo "M3  idempotence removed (same origin re-applied does the full dance)"
mutate "$LIB" 's|^    if \[\[ "$active_origin" == "$origin" \]\]; then|    if false; then|'
check "M3 re-apply is a no-op" "re-applying the same origin is a no-op"

echo "M4  mutual exclusion removed (a second method is granted)"
mutate "$LIB" 's|^    elif \[\[ "$active_method" != "$method" \]\]; then|    elif false; then|'
check "M4 second method refused" "a second, different access method is REFUSED and the holder is named"

echo "M5  refusal no longer names the owner"
mutate "$LIB" 's|^      echo "         owner:  ${owner:-<unknown>}" >\&2|      :|'
check "M5 refusal names the holder" "a second, different access method is REFUSED and the holder is named"

echo "M6  same method may NOT re-publish on a new origin"
mutate "$LIB" 's|^    elif \[\[ "$active_method" != "$method" \]\]; then|    elif true; then|'
check "M6 ngrok re-up still works" "the same access method may re-publish on a NEW origin"

echo "M7  restore DELETES the origin key instead of setting the baseline"
mutate "$LIB" 's|^  _dex_origin_write "$DEX_ORIGIN_BASELINE" "" \|\| return 1|  _dex_origin_write "" "" \|\| return 1|'
check "M7 restore sets the baseline" "restore returns the baseline exactly and releases the lease"

echo "M8  restore leaves the lease keys behind"
mutate "$LIB" 's|^    lease="\\"${DEX_ORIGIN_KEY_METHOD}\\":null|    lease="\\"UNUSED_KEY\\":null|'
check "M8 restore releases the lease" "restore returns the baseline exactly and releases the lease"

echo "M9  trailing slash / path no longer rejected"
mutate "$LIB" 's|^    elif \[\[ "$rest" == \*/\* \]\]; then|    elif false; then|'
check "M9 malformed origin rejected" "a malformed origin is rejected"

echo "M10 applying the baseline takes a lease instead of releasing"
mutate "$LIB" 's|^  if \[\[ "$origin" == "$DEX_ORIGIN_BASELINE" \]\]; then|  if false; then|'
check "M10 baseline is a release" "applying the resting baseline is a release, not a lease"

# The obvious mutation here — appending `|| true` to the guarded patch — is
# WRONG and was tried first: `if ! cmd || true` parses as `(! cmd) || true`, so
# the error branch fires unconditionally and thirteen tests go red. That is the
# harness breaking the subject, not the guard failing to fire. Mutating the
# `return 1` instead introduces exactly the intended defect (the write fails, the
# caller carries on regardless) and nothing else.
echo "M11 a failed lease write is reported but not fatal"
mutate "$LIB" '/Without it the origin is not published/{n;s/return 1/return 0/}'
check "M11 failed write is fatal" "a failed write to the lease namespace is fatal, not silent"

echo "M12 OCIRepository refresh dropped (Kustomization reconciled alone)"
mutate "$LIB" 's|^      "$DEX_ORIGIN_FLUX" reconcile source oci "$src" -n "$ns" >/dev/null 2>&1 \|\| true|      :|'
check "M12 source refreshed before kustomization" "applying an origin reconciles both consumers and restarts Dex"

echo "M13 Dex restart dropped"
mutate "$LIB" 's|^  "$DEX_ORIGIN_KUBECTL" rollout restart "deployment/${DEX_ORIGIN_DEX_DEPLOYMENT}" \\|  return 0 \&\& \\|'
check "M13 Dex is restarted" "applying an origin reconciles both consumers and restarts Dex"

echo "M14 a manifest default drifts away from the baseline"
mutate "$DEX_MANIFEST" 's|issuer: ${PUBLIC_ORIGIN:=https://dashboard.osramp.acme.local:30754}/dex|issuer: ${PUBLIC_ORIGIN:=https://dashboard.osramp.acme.local:31337}/dex|'
check "M14 manifest baseline drift" "the baseline still matches every manifest default that carries the origin"

echo "M15 expose.sh goes back to patching the ConfigMap itself"
mutate "$EXPOSE" 's|^publish_origin() {|publish_origin() {\n  kubectl patch configmap flux-runtime-info -n flux-system --type=merge -p "x"|'
check "M15 expose.sh delegates" "expose.sh delegates to the mechanism rather than patching in parallel"

echo ""
echo "=== restored: the suite must be green again ==="
restore_all
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green after restore" >&2
  exit 2
fi
echo "  GREEN"
echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
