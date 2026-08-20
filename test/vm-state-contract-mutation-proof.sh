#!/usr/bin/env bash
#
# vm-state-contract-mutation-proof.sh
#   Prove test/terraform-vm-state-contract.bats can fail, by breaking the REAL
#   gate one defect at a time and confirming the RIGHT test goes red.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` dead under `set -e`, a `[ "$status" -ne 0 ]` that read a MISSING
# FILE as "pattern absent", a mechanism assertion that passed vacuously because
# its own discovery returned empty. Every one of them was green.
#
# ── Naming IS registration ──────────────────────────────────────────────────
#
# `GCP_TF_PROOFS = $(wildcard test/*-mutation-proof.sh)` picks this file up the
# moment it is named. NOTHING ELSE IS REQUIRED, and adding a hand-registered
# Makefile variable for it is actively harmful — it runs the proof TWICE on a
# gate that already takes ~13 minutes. That has already happened here once and
# was caught in review, not by the gate, because a duplicate run is green.
#
# ── §7b: mutate the REAL file ───────────────────────────────────────────────
#
# Restore is from a byte-for-byte backup taken OUTSIDE THE REPOSITORY, not
# `git checkout`. `git checkout <path>` in a proof harness silently reverts
# in-progress edits elsewhere in the tree, and the resulting "the guard did not
# fire" reads exactly like a real finding.
#
# Run: test/vm-state-contract-mutation-proof.sh

set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
GATE="${REPO_ROOT}/scripts/vm-state/vm-state-contract.sh"
SUITE="${REPO_ROOT}/test/terraform-vm-state-contract.bats"

# ── The sentinel, now shared ────────────────────────────────────────────────
#
# This harness had a correct, hand-rolled sentinel; it is now the shared rail in
# test/helpers/mutation-sentinel.bash so that all eight proofs get the same
# behaviour instead of three of them having it. The rail keeps everything this
# version did and closes three gaps it had:
#
#   * `restore_all` deleted the sentinel BEFORE the hash was compared, so a
#     FAILED restore exited 2 with no marker left behind — the one case the
#     sentinel exists for. The rail clears it only on a verified restore.
#   * The mode was never checked. `cp` onto an existing file keeps the
#     DESTINATION's mode, so a mutation applied by `mv` from a tempfile restores
#     byte-identical with the +x bit gone, and sha256 cannot see it.
#   * A live pid in the sentinel now reads as "a run is in progress", not as a
#     leaked mutation. They need opposite responses.
#
# Naming is unchanged and still unique to this harness: a shared name means one
# harness's restore deletes another's marker, and the second then cannot tell it
# left a file mutated. `.gitignore` already covers *mutation-in-progress.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

[ -f "$SUITE" ] || { echo "HARNESS ERROR: suite not found at ${SUITE}" >&2; exit 2; }

ms_guard_init vm-state-contract "$GATE"
trap ms_guard_on_exit EXIT

ORIG_HASH="${MS_SHAS[0]}"

PASS=0
FAIL=0

restore_all() { ms_guard_restore; }

# ── A sed that cannot silently do nothing ───────────────────────────────────
#
# A non-matching sed program no-ops while returning 0. The mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one. So the hash is compared and a
# no-op aborts the whole run.
#
# Every sed program below is SINGLE-QUOTED precisely so `$` stays literal: these
# patterns match shell variables in the gate's source, they do not expand them.
# Double-quoting would expand `${pin}` against this harness's own environment,
# produce a pattern matching nothing, and abort here.
# shellcheck disable=SC2016
#
# ms_sed arms the sentinel itself, so the mutation can never land with nothing
# on disk recording that it did. It also separates a sed SYNTAX ERROR from a
# pattern that no longer matches — this version conflated them into one
# "HARNESS ERROR", and an unescaped `|` reads identically to a dead guard.
mutate() { ms_sed "$GATE" "$1"; }

# Runs the suite and reports the NAMES of the tests that failed.
#
# Names, not the `not ok <n>` numbers: inserting two tests in the middle of a
# suite renumbers everything below, and a harness that reports NOT PROVEN for a
# guard that fired perfectly well is worse than no harness, because the natural
# response is to go and "fix" working code.
#
# A non-zero bats is the EXPECTED outcome, and `set -o pipefail` promotes it to
# the pipeline's status — hence `|| true` at the call site, or the harness dies
# on its own first success.
failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() { # label expected_test_name
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

echo "M1  pin extraction no longer anchored to a declaration line"
mutate 's#"\^(readonly#"(readonly#'
check "M1 pins come from declarations" "pins are read from declarations only, never from prose that mentions a version"

echo "M2  version match degraded to a substring"
mutate 's#\[^0-9\.\]#.*#g'
check "M2 version boundaries" "a pinned version is not satisfied by a longer number that contains it"

echo "M3  fact 6 drops the sudo escalation path (asserts bare writability)"
mutate 's#elif \[ "$sudo_ok" -eq 1 \]; then#elif false; then#'
check "M3 escalation counts" "F6 PASSES when the bin dir is unwritable but sudo is available"

echo "M4  fact 6 accepts a machine with neither write nor sudo"
mutate 's#elif \[ "$sudo_ok" -eq 1 \]; then#elif true; then#'
check "M4 no-path-to-write is fatal" "F6 goes red only when BOTH the direct write and the escalation are gone"

echo "M5  fact 8 asks the credential set instead of the daemon"
mutate 's#out="$(docker info 2>&1)"#out="$(id -nG 2>\&1)"#'
check "M5 docker capability" "F8 goes red when docker is present but cannot reach the daemon"

echo "M6  fact 8 consults group membership, the check that passes while docker fails"
mutate 's#out="$(docker info 2>&1)"#out="$(getent group docker 2>\&1)"#'
check "M6 getent is not a probe" "F8 does not consult group membership, which passes while docker fails"

echo "M7  failure COUNT stops counting (reports 1 however many failed)"
mutate 's#FAILED=$((FAILED + 1))#FAILED=1#'
check "M7 every failure reported" "every failure is reported, not just the first"

echo "M8  a present-but-broken tool is accepted as runnable"
mutate '/^fact_runnable_tool()/,/^}/ s#if \[ "$rc" -eq 0 \]; then#if true; then#'
check "M8 running beats -x" "F5 goes red when uv is present but cannot run"

echo "M9  an unwritable directory is accepted as long as it exists"
mutate '/^fact_dir_writable()/,/^}/ s#if \[ "$rc" -eq 0 \]; then#if true; then#'
check "M9 existence is not writability" "F7 distinguishes 'missing' from 'present but unwritable'"

echo "M10 a missing pin source degrades to two silently-skipped facts"
mutate 's#if \[ ! -f "${VMSC_PIN_FILE}" \]; then#if false; then#'
check "M10 harness error is distinct" "a missing pin source is a harness error, not eight facts silently becoming seven"

echo "M11 one fact is dropped from the run"
mutate '/fact_runnable_tool F5-uv-runnable/d'
check "M11 fact count cannot shrink" "all nine facts are evaluated, so the count cannot silently shrink"

echo "M12 remedies are no longer marked, so failures carry no action"
# The `%s\n` context is not decoration. A bare `s#      -> #      #` also matches
# the COMMENT block in fact_docker_usable, which lines up example output with
# `docker info          ->  permission denied`. sed would mutate that comment
# instead, the hash would change, the no-op guard would be satisfied — and the
# suite would stay green, reporting NOT PROVEN for a guard that is fine. A
# mutation that lands on the wrong line is indistinguishable from one that does
# not land at all, except that the no-op check cannot see it.
mutate 's#      -> %s\\n#      %s\\n#'
check "M12 failures name a remedy" "every failure carries a remedy naming what to do"

echo "M13 the json failure count is hardcoded"
mutate 's#"$FAILED" "$n"#0 "$n"#'
check "M13 json reports reality" "json output is emitted and carries the failure count"

echo ""
echo "=== result ==="
echo "  proven:    ${PASS}"
echo "  unproven:  ${FAIL}"
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "A mutation that fails NOTHING is a finding, not a nuisance." >&2
  echo "Fix the assertion before moving on." >&2
  exit 1
fi
exit 0
