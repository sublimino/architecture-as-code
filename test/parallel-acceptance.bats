#!/usr/bin/env bats
# @id     parallel-acceptance
# @target scripts/parallel-acceptance.sh
# @doc    docs/signalloom/runbooks/parallel-tests.md
#
# The claim under test is "exits 0 only if BOTH children pass". A suite that
# only ever ran the real thing could not prove the failure direction without
# paying ~10 minutes per case, so PARALLEL_ACCEPTANCE_CMD swaps in a stub child.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/parallel-acceptance.sh"
  STUB="${BATS_TEST_TMPDIR}/stub.sh"
  OUT="${BATS_TEST_TMPDIR}/out"
  export REPO_ROOT SCRIPT STUB OUT
  export KUBECONFIG=/dev/null
}

# write_stub <body>: a child that receives its outdir as $1, like the real one.
write_stub() {
  cat >"$STUB" <<EOF
#!/usr/bin/env bash
set -uo pipefail
out="\$1"; mkdir -p "\$out"
$1
EOF
  chmod +x "$STUB"
}

@test "parallel-acceptance: passes when both children pass" {
  write_stub 'echo "stub ok" ; printf "suite rc=0 pass=3 fail=0\n" > "$out/totals.key" ; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"parallel-acceptance: PASS"* ]]
  [ "$(cat "$OUT/A/rc")" = "0" ]
  [ "$(cat "$OUT/B/rc")" = "0" ]
}

@test "parallel-acceptance: FAILS when exactly one child fails (A)" {
  # Exactly one failure is the case that distinguishes "both must pass" from
  # "either may pass", so the stub must pick its run DETERMINISTICALLY.
  # TEST_PORT_BASE is distinct per run by construction; a marker file would
  # race and let both children take the same branch.
  write_stub 'if [ "$TEST_PORT_BASE" = "21000" ]; then exit 7; fi; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"parallel-acceptance: FAIL"* ]]
  [ "$(cat "$OUT/A/rc")" = "7" ]
  [ "$(cat "$OUT/B/rc")" = "0" ]
}

@test "parallel-acceptance: FAILS when exactly one child fails (B)" {
  # The mirror case: a harness that only checked the first child would pass
  # the test above and fail this one.
  write_stub 'if [ "$TEST_PORT_BASE" = "41000" ]; then exit 7; fi; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"parallel-acceptance: FAIL"* ]]
  [ "$(cat "$OUT/A/rc")" = "0" ]
  [ "$(cat "$OUT/B/rc")" = "7" ]
}

@test "parallel-acceptance: FAILS when both children fail" {
  write_stub 'exit 3'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 1 ]
  [ "$(cat "$OUT/A/rc")" = "3" ]
  [ "$(cat "$OUT/B/rc")" = "3" ]
}

@test "parallel-acceptance: FAILS when a child fails only sometimes (the flake case)" {
  # The point of the harness: a suite that passes alone and fails concurrently.
  # This stub fails whenever it sees a sibling already running.
  write_stub '
lock="'"${BATS_TEST_TMPDIR}"'/running"
if mkdir "$lock" 2>/dev/null; then
  sleep 1; rmdir "$lock"; exit 0
else
  echo "collided with a concurrent run" >&2; exit 1
fi'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  grep -q "collided with a concurrent run" "$OUT"/*/console.log
}

@test "parallel-acceptance: the two children get separate GOCACHE, GOMODCACHE, GOPATH, TMPDIR and TEST_PORT_BASE" {
  write_stub 'printf "%s\n%s\n%s\n%s\n%s\n" "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$TMPDIR" "$TEST_PORT_BASE" > "$out/env.txt"; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  # every one of the five values differs between A and B
  run diff "$OUT/A/out/env.txt" "$OUT/B/out/env.txt"
  [ "$status" -ne 0 ]
  differing="$(diff --unchanged-line-format= --old-line-format='%L' --new-line-format= \
      "$OUT/A/out/env.txt" "$OUT/B/out/env.txt" | grep -c .)"
  [ "$differing" -eq 5 ]
  # and the directories really exist, i.e. they were created not just named
  [ -d "$(sed -n 1p "$OUT/A/out/env.txt")" ]
  [ -d "$(sed -n 4p "$OUT/B/out/env.txt")" ]
}

@test "parallel-acceptance: children actually overlap in time" {
  # If the two runs were sequential the whole harness would be worthless, so
  # assert the overlap rather than assuming it.
  write_stub 'date +%s%N > "$out/start"; sleep 2; date +%s%N > "$out/end"; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  a_start="$(cat "$OUT/A/out/start")"; a_end="$(cat "$OUT/A/out/end")"
  b_start="$(cat "$OUT/B/out/start")"; b_end="$(cat "$OUT/B/out/end")"
  # overlap iff a_start < b_end and b_start < a_end
  [ "$a_start" -lt "$b_end" ]
  [ "$b_start" -lt "$a_end" ]
}

@test "parallel-acceptance: differing totals between concurrent runs fail even when both children exit 0" {
  # Two runs of the same tree at the same commit that disagree on counts have
  # interfered, whatever their exit codes say.
  # Key the differing totals off TEST_PORT_BASE, which is distinct per run by
  # construction. A `test -f` / `touch` pair would race -- both children can
  # see the marker absent and then agree, which is exactly how this case first
  # passed when it should have failed.
  write_stub '
if [ "$TEST_PORT_BASE" = "21000" ]; then
  printf "suite rc=0 pass=10 fail=0\n" > "$out/totals.key"
else
  printf "suite rc=0 pass=9 fail=1\n" > "$out/totals.key"
fi
exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"totals differ between concurrent runs"* ]]
}

@test "parallel-acceptance: forwards TEST_TIMEOUT_SCALE and defaults it to 2" {
  write_stub 'echo "$TEST_TIMEOUT_SCALE" > "$out/scale.txt"; exit 0'
  PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/A/out/scale.txt")" = "2" ]

  TEST_TIMEOUT_SCALE=7 PARALLEL_ACCEPTANCE_CMD="$STUB" run bash "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/A/out/scale.txt")" = "7" ]
}
