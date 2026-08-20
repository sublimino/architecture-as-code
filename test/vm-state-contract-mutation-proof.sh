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

# ── The sentinel ────────────────────────────────────────────────────────────
#
# Dropped while a real file is mutated, removed on restore. If a previous run
# was SIGKILLed (a tool timeout escalates to SIGKILL, which no trap survives)
# the mutated file is still on disk and the sentinel is the only thing that
# knows. REFUSE TO START. Do NOT auto-repair: a harness that silently restores
# makes the next run green and hides the fact that a mutated file has been
# sitting in the tree — and possibly been committed.
#
# The name is unique to THIS harness, deliberately. A sentinel shared between
# harnesses means one harness's restore deletes another's marker, and the second
# harness then cannot tell that it left a file mutated.
# .gitignore already covers *mutation-in-progress.
SENTINEL="${REPO_ROOT}/.vm-state-contract-mutation-in-progress"

if [ -e "$SENTINEL" ]; then
  echo "REFUSING TO START: ${SENTINEL} exists." >&2
  echo "" >&2
  echo "  A previous run of this harness did not restore its mutation." >&2
  echo "  A file under scripts/vm-state/ is probably still mutated." >&2
  echo "" >&2
  echo "  This is NOT auto-repaired on purpose. Inspect the damage first:" >&2
  echo "      git -C ${REPO_ROOT} diff -- scripts/vm-state/" >&2
  echo "  restore it deliberately, then remove the sentinel." >&2
  exit 2
fi

[ -f "$GATE" ]  || { echo "HARNESS ERROR: gate not found at ${GATE}" >&2; exit 2; }
[ -f "$SUITE" ] || { echo "HARNESS ERROR: suite not found at ${SUITE}" >&2; exit 2; }

# ── Backup, outside the repo ────────────────────────────────────────────────

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vmsc-proof.XXXXXX")"
cp "$GATE" "${BACKUP_DIR}/gate.orig"
ORIG_HASH="$(sha256sum "$GATE" | cut -d' ' -f1)"

PASS=0
FAIL=0

restore_all() {
  cp "${BACKUP_DIR}/gate.orig" "$GATE"
  rm -f "$SENTINEL"
}

# The EXIT trap must not rewrite the verdict.
#
# Under `set -e` a failing LAST command inside an EXIT trap replaces the script's
# exit status. That has already turned an 8/8-green run in this repo into a
# reported failure. So the status is captured first and re-raised explicitly.
on_exit() {
  local status=$?
  restore_all
  local now
  now="$(sha256sum "$GATE" | cut -d' ' -f1)"
  if [ "$now" != "$ORIG_HASH" ]; then
    echo "*** RESTORE FAILED: ${GATE} does not match its pre-mutation hash." >&2
    echo "    expected ${ORIG_HASH}" >&2
    echo "    found    ${now}" >&2
    rm -rf "$BACKUP_DIR"
    exit 2
  fi
  rm -rf "$BACKUP_DIR"
  exit "$status"
}
trap on_exit EXIT

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
mutate() { # sed_program
  local before after
  before="$(sha256sum "$GATE" | cut -d' ' -f1)"
  touch "$SENTINEL"
  sed -i "$1" "$GATE" || { echo "HARNESS ERROR: sed failed: $1" >&2; exit 2; }
  after="$(sha256sum "$GATE" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    echo "HARNESS ERROR: mutation changed nothing — the pattern no longer matches." >&2
    echo "               ${1}" >&2
    echo "               Fix the pattern; do NOT treat the resulting green as a proof." >&2
    exit 2
  fi
}

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
