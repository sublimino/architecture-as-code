#!/usr/bin/env bash
# SLAWS acceptance harness: the six offline commands from the proposal's Mission identity,
# one totals line per command, machine-comparable across two consecutive runs.
#   usage: scripts/slaws-acceptance.sh <outdir>
# Totals are parsed from go test -v ("--- PASS"/"--- FAIL") and bats ("ok"/"not ok").
# Go caching is disabled by the Makefile targets (-count=1); a fresh GOCACHE is NOT forced
# so build cache is reused, test results are not.
set -u
out="${1:?outdir}"; mkdir -p "$out"
root="$(cd "$(dirname "$0")/.." && pwd)"; cd "$root"
export KUBECONFIG=/dev/null
run() {
  local name="$1"; shift
  local s; s=$(date +%s)
  local rc=0
  "$@" > "$out/$name.log" 2>&1 || rc=$?
  local pass fail
  pass=$(grep -cE '^(ok [0-9]+|--- PASS|=== RUN)' "$out/$name.log" 2>/dev/null || true)
  fail=$(grep -cE '^(not ok [0-9]+|--- FAIL|FAIL\s)' "$out/$name.log" 2>/dev/null || true)
  printf '%-24s rc=%d pass=%s fail=%s %ss\n' "$name" "$rc" "${pass:-0}" "${fail:-0}" "$(( $(date +%s) - s ))" | tee -a "$out/totals.txt"
}
: > "$out/totals.txt"
echo "head_start=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ')" | tee "$out/head.txt"
run signal-ingest          make test-signal-ingest
run signal-ingest-frostdb  make test-signal-ingest-frostdb
run policy-engine          bash -c 'cd d2-signalloom/apps/policy-engine && env GOCACHE=${GOCACHE:-/tmp/gocache} GOMODCACHE=${GOMODCACHE:-/tmp/gomodcache} go test -count=1 -v ./...'
run sldc-offline           make test-sldc-offline
run probe-name             bash scripts/check-old-probe-name.sh
run docs-lint              make docs-lint
# Beyond the six: pkg/obscel is its own module and is reached by none of the six commands.
# Recorded alongside so the shared vocabulary is counted, not assumed.
run obscel-extra           make test-obscel
# Beyond the six: docs-lint checks links, paths and style, and none of the six
# checks that what a doc CLAIMS about a test is true. Recorded alongside so a
# renamed test or a moved suite is counted, not assumed.
run alignment              make test-alignment
echo "head_end=$(git rev-parse HEAD)" | tee -a "$out/head.txt"
# Comparable key: everything except elapsed seconds.
sed -E 's/ [0-9]+s$//' "$out/totals.txt" > "$out/totals.key"
if grep -q 'rc=[1-9]' "$out/totals.txt"; then echo "ACCEPTANCE: FAIL" ; exit 1; fi
echo "ACCEPTANCE: PASS"
