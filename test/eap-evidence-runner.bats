#!/usr/bin/env bats
#
# scripts/run-e2e-dual-cluster-containment.sh must report the containment
# suite's real outcome. The suite itself is replaced by a stub `bats` on PATH,
# so no cluster is touched and the runner's own bookkeeping is what is tested.
#
# @target scripts/run-e2e-dual-cluster-containment.sh

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	runner="$root/scripts/run-e2e-dual-cluster-containment.sh"
	stub="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stub"
	# Stub suite: 1..5 with step 4 red when STUB_FAIL=1; records its EVIDENCE_DIR.
	cat >"$stub/bats" <<'EOF'
#!/usr/bin/env bash
echo "$EVIDENCE_DIR" >>"$STUB_LOG"
echo "1..5"
for s in 1 2 3 4 5; do
  if [ "${STUB_FAIL:-0}" = 1 ] && [ "$s" = 4 ]; then echo "not ok $s Step $s"; else echo "ok $s Step $s"; fi
done
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
	chmod +x "$stub/bats"
	export PATH="$stub:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	ev="$BATS_TEST_TMPDIR/ev"
}

@test "a green suite: exit 0 and a summary recording exit 0, 5 passed" {
	run bash "$runner" --evidence-dir "$ev"
	[ "$status" -eq 0 ]
	[ "$(jq -r '"\(.exit) \(.passed) \(.failed)"' "$ev/run-summary.json")" = "0 5 0" ]
	[ "$(cat "$STUB_LOG")" = "$ev" ]
}

@test "a red suite: the runner exits 1 and the summary records the suite's exit 1" {
	STUB_FAIL=1 run bash "$runner" --evidence-dir "$ev"
	[ "$status" -eq 1 ]
	[ "$(jq -r '"\(.exit) \(.passed) \(.failed)"' "$ev/run-summary.json")" = "1 4 1" ]
}

@test "--repeat 2 with a red suite: every run recorded red, runner exits 1" {
	STUB_FAIL=1 run bash "$runner" --evidence-dir "$ev" --repeat 2
	[ "$status" -eq 1 ]
	[ "$(jq -r .exit "$ev/run-1/run-summary.json")" = 1 ]
	[ "$(jq -r .exit "$ev/run-2/run-summary.json")" = 1 ]
}

@test "evidence dir is created 0750 and the runner never writes under HOME when given one" {
	HOME="$BATS_TEST_TMPDIR/home" run bash "$runner" --evidence-dir "$ev"
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$ev")" = 750 ]
	[ ! -e "$BATS_TEST_TMPDIR/home" ]
}

@test "usage errors exit 2: bad --repeat, unknown option" {
	run bash "$runner" --evidence-dir "$ev" --repeat 0
	[ "$status" -eq 2 ]
	[[ "$output" == *"--repeat must be a positive integer"* ]]
	run bash "$runner" --bogus
	[ "$status" -eq 2 ]
}
