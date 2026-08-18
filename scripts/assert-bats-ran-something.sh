#!/usr/bin/env bash
#
# Run a bats suite and fail if every test skipped.
#
# WHY THIS EXISTS
#
# On 2026-08-18 six user-visible live-data failures were live in the product
# while `make test` — whose help text reads "Run the end-to-end bats suite
# against the running cluster" — exited 0 with this output:
#
#     1..8
#     ok 1 reset the debug file # skip namespace/frontend not deployed
#     ok 2 example test with setup/retry and pipes # skip namespace/frontend not deployed
#     ... (all 8)
#
# Eight tests, eight skips, zero assertions executed, exit 0, and a summary line
# a human reads as "the end-to-end suite passed". TAP is behaving correctly here
# — a skip IS an `ok` line — but the aggregate is not: a suite whose every test
# declined to run has told you nothing about the system, and reporting that as
# success is the same defect this repo keeps finding elsewhere. Absence read as
# confirmation.
#
# The rule is deliberately about the AGGREGATE, not about individual skips. A
# suite that skips 3 of 40 because 3 optional slices are absent is working as
# designed. A suite that skips 40 of 40 has been handed an environment it cannot
# test, and the only honest answer is to say so loudly rather than to pass.
#
# Usage:
#     scripts/assert-bats-ran-something.sh <command...>
#
# Exits with the wrapped command's status, unless that status is 0 AND every
# reported test skipped, in which case it exits 1.

set -eo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <command...>" >&2
  exit 64
fi

output_file="$(mktemp)"
trap 'rm -f "${output_file}"' EXIT

# tee rather than capture-then-print: a suite that takes minutes should stream,
# and a suite that dies half way should still show what it got to.
set +e
"$@" 2>&1 | tee "${output_file}"
status="${PIPESTATUS[0]}"
set -e

if [[ "${status}" -ne 0 ]]; then
  exit "${status}"
fi

# Count TAP result lines. `ok N` and `not ok N` are the only two forms; a skip
# is an `ok` line carrying a `# skip` directive.
total="$(grep -cE '^(not )?ok [0-9]+' "${output_file}" || true)"
skipped="$(grep -cE '^ok [0-9]+.*# skip' "${output_file}" || true)"

if [[ "${total}" -eq 0 ]]; then
  echo "" >&2
  echo "ERROR: the suite reported no TAP results at all." >&2
  echo "       It exited 0 having executed nothing that can be counted." >&2
  echo "       Command: $*" >&2
  exit 1
fi

if [[ "${total}" -eq "${skipped}" ]]; then
  echo "" >&2
  echo "ERROR: all ${total} test(s) skipped — the suite proved nothing." >&2
  echo "       Exit 0 here would report an untested system as a passing one." >&2
  echo "       Command: $*" >&2
  echo "" >&2
  echo "       Reasons given:" >&2
  grep -oE '# skip.*' "${output_file}" | sort | uniq -c | sed 's/^/         /' >&2
  echo "" >&2
  echo "       If the target slice is genuinely not deployed, deploy it and" >&2
  echo "       re-run. Do not silence this by removing the guard: a suite that" >&2
  echo "       cannot run is not a suite that passed." >&2
  exit 1
fi

echo ""
echo "assert-bats-ran-something: ${total} test(s) reported, ${skipped} skipped — suite executed."
