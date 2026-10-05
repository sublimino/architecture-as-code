#!/usr/bin/env bash
# Run two full acceptance passes CONCURRENTLY and pass only if both pass.
#
# This is the executable form of the requirement: "parallel tests shouldn't
# interfere with each other; we should be able to pass multiple test runs 100%."
# Running the suite twice in sequence proves nothing about interference --
# interference only shows up when the two runs overlap in time.
#
# What is separated per run, and why each one matters:
#   GOCACHE / GOMODCACHE / GOPATH  Go's caches are lock-protected, so sharing
#       them is safe but serialises the two runs on the lock and hides timing
#       interference behind cache hits. Separate caches make the test honest.
#   output directory              scripts/slaws-acceptance.sh writes
#       $out/<name>.log and $out/totals.txt; one directory would interleave.
#   TMPDIR                        anything that honours it stops sharing /tmp.
#   TEST_PORT_BASE                advisory, exported for any test that wants a
#       per-run offset. Nothing in the tree needs it today -- the convention
#       here is free_port()/`:0`, which needs no base at all -- but it is
#       exported so a suite that genuinely cannot ask the kernel has somewhere
#       to start that is not shared.
#
#   usage: scripts/parallel-acceptance.sh [outdir]
#   env:   PARALLEL_ACCEPTANCE_CMD  command each child runs (default
#                                   scripts/slaws-acceptance.sh). Overridable
#                                   so the bats suite can prove this script
#                                   detects a FAILING child without paying
#                                   ~10 minutes for a real acceptance run.
#          TEST_TIMEOUT_SCALE       forwarded to children; defaults to 2 here,
#                                   because two concurrent passes IS the load.
#
# @id    parallel-acceptance
# @doc   docs/signalloom/runbooks/parallel-tests.md
# @tests test/parallel-acceptance.bats
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# The output root defaults OUTSIDE the repository: an in-tree directory dirties the
# checkout, places TMPDIR inside a git repository (which breaks "fails closed outside a
# git repository" tests) and produces unix-socket paths longer than sun_path allows.
OUT="${1:-${PARALLEL_ACCEPTANCE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/parallel-acceptance.XXXXXX")}}"
CMD="${PARALLEL_ACCEPTANCE_CMD:-scripts/slaws-acceptance.sh}"
export TEST_TIMEOUT_SCALE="${TEST_TIMEOUT_SCALE:-2}"

rm -rf "$OUT"
mkdir -p "$OUT"

start_run() { # <label> <port_base>
  local label="$1" base="$2"
  local dir="${OUT}/${label}"
  mkdir -p "$dir/out" "$dir/gocache" "$dir/gomodcache" "$dir/gopath" "$dir/tmp"
  (
    export GOCACHE="$dir/gocache"
    export GOMODCACHE="$dir/gomodcache"
    export GOPATH="$dir/gopath"
    export TMPDIR="$dir/tmp"
    export TEST_PORT_BASE="$base"
    export KUBECONFIG=/dev/null
    export CGO_ENABLED=0
    # shellcheck disable=SC2086
    bash $CMD "$dir/out"
  ) >"${dir}/console.log" 2>&1
  echo "$?" >"${dir}/rc"
}

echo "parallel-acceptance: two concurrent passes of '$CMD'"
echo "  outdir            $OUT"
echo "  TEST_TIMEOUT_SCALE=$TEST_TIMEOUT_SCALE"
started="$(date +%s)"

start_run A 21000 &
pid_a=$!
start_run B 41000 &
pid_b=$!

wait "$pid_a"
wait "$pid_b"

rc_a="$(cat "${OUT}/A/rc" 2>/dev/null || echo 99)"
rc_b="$(cat "${OUT}/B/rc" 2>/dev/null || echo 99)"
elapsed=$(( $(date +%s) - started ))

echo
echo "parallel-acceptance: A rc=$rc_a   B rc=$rc_b   ${elapsed}s"

# Where the two runs produced comparable totals, show them side by side: a
# difference in PASS counts between two runs of the same tree at the same commit
# is itself interference, even when both runs exit 0.
if [ -f "${OUT}/A/out/totals.key" ] && [ -f "${OUT}/B/out/totals.key" ]; then
  if diff -u "${OUT}/A/out/totals.key" "${OUT}/B/out/totals.key" >"${OUT}/totals.diff"; then
    echo "parallel-acceptance: totals identical across both runs"
  else
    echo "parallel-acceptance: WARNING totals differ between concurrent runs" >&2
    sed -n '1,40p' "${OUT}/totals.diff" >&2
    rc_a=$(( rc_a != 0 ? rc_a : 1 ))
  fi
fi

if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
  echo "parallel-acceptance: FAIL (A=$rc_a B=$rc_b)" >&2
  echo "  logs: ${OUT}/A/console.log ${OUT}/B/console.log" >&2
  exit 1
fi
echo "parallel-acceptance: PASS"
