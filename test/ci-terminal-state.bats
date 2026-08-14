#!/usr/bin/env bats
#
# The state a CI run leaves behind must say which run it belongs to and how that
# run ended. On 2026-08-13 it did not, three times in one session:
#
#   1. Both lanes aborted before stage 1. gcp-ci.sh deliberately leaves a VM
#      RUNNING on failure, so the operators suspended them by hand — and
#      SUSPENDED is also the documented SUCCESS state. "SUSPENDED, ci-reports/
#      holding only wait-stats.txt" is what you see after a clean pass whose
#      collection failed, after an abort, and after a run that never started.
#      Only `gcloud ... --format='value(lastStartTimestamp)'` separated them.
#   2. A poll read ci-reports/summary.json and got `5444d45 FAIL 8/12` — the
#      PREVIOUS round's report, still on disk because the new run had not
#      collected yet. Two rounds, two commits, one filename.
#   3. A VM status taken 14 seconds before the VM was resumed was relayed as
#      "it has not started". Accurate when taken, wrong on arrival.
#
# Twice that ambiguity was nearly reported as a pass. These tests drive the real
# functions — lifted out of the scripts with sed, as test/gcp-ci-vm-status.bats
# does — against temp directories and stub inputs. No gcloud, no VM, no network.
# Lifting rather than re-implementing is the point: a reworded implementation
# cannot silently stop being covered.

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	gcp="${repo_root}/scripts/ci/gcp-ci.sh"
	pipeline="${repo_root}/scripts/ci/vm-pipeline.sh"
	report_dir="$BATS_TEST_TMPDIR/ci-reports"
	mkdir -p "$report_dir"
}

# Lift a function verbatim out of a script.
lift() {
	sed -n "/^$2() {/,/^}/p" "$1"
}

# ─── The pipeline's own terminal artefact ───────────────────────────────────
#
# vm-pipeline.sh runs on the VM. It is the only thing that knows how far a run
# got, and until now it wrote nothing at all unless it reached the report stage.

# Builds a probe that installs the REAL trap and then exits with a chosen
# status, optionally with some pipeline state already set.
pipeline_probe() {
	local rc="$1" phase="$2" extra="${3:-}"
	local probe="$BATS_TEST_TMPDIR/pipeline-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\n' "$report_dir"
		printf 'CI_SOURCE_COMMIT=%q\nCI_SOURCE_BRANCH=%q\n' "fb79dfb" "fix/ci-terminal-state-honesty"
		lift "$pipeline" json_str
		lift "$pipeline" write_terminal_summary
		lift "$pipeline" on_pipeline_exit
		printf 'PIPELINE_PHASE=%q\n' "$phase"
		# The wiring is lifted, not re-typed: a probe that installs its own trap
		# would keep passing after the trap was removed from the real script.
		grep -Ex 'trap on_pipeline_exit EXIT' "$pipeline" || true
		printf '%s\n' "$extra"
		printf 'exit %d\n' "$rc"
	} >"$probe"
	bash "$probe"
}

@test "CITERM an aborted pipeline leaves a machine-readable ABORTED artefact" {
	run pipeline_probe 2 "create-cluster"
	[ "$status" -eq 2 ]
	[ -f "$report_dir/summary.json" ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
}

@test "CITERM the aborted artefact names the phase, commit, branch and exit code" {
	# Without these a reader is still inferring — which is the whole defect.
	pipeline_probe 2 "create-cluster" || true
	run jq -r '[.phase, .commit, .branch, (.exit_code|tostring)] | join("|")' \
		"$report_dir/summary.json"
	[ "$output" = "create-cluster|fb79dfb|fix/ci-terminal-state-honesty|2" ]
}

@test "CITERM the aborted artefact says in words that it is not a test failure" {
	# The wrapper already prints this and it is correct; it just evaporates with
	# the terminal. Put it somewhere that survives.
	pipeline_probe 2 "pull-code" || true
	run jq -r '.note' "$report_dir/summary.json"
	[[ "$output" == *"ABORTED"* ]]
	[[ "$output" == *"NOT a test result"* ]]
}

@test "CITERM overall is ABORTED too, so a reader of the old field is not misled" {
	pipeline_probe 2 "build-images" || true
	run jq -r '.overall' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
	[ "$output" != "PASS" ]
}

@test "CITERM a real verdict is never overwritten by the abort writer" {
	# The trap runs on the success path too. If it clobbered the summary, every
	# run would report ABORTED and this change would be worse than the defect.
	printf '{"outcome":"PASS","overall":"PASS","commit":"fb79dfb","passed":12}\n' \
		>"$report_dir/summary.json"
	run pipeline_probe 0 "report"
	[ "$status" -eq 0 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "PASS" ]
}

@test "CITERM the exit trap does not rewrite the run's exit status" {
	# Under `set -e` an EXIT trap hands its own last status to the shell. That is
	# how a run with 8/8 stages green once exited 1 (see test/ci-lock.bats).
	run pipeline_probe 7 "tests"
	[ "$status" -eq 7 ]
	rm -f "$report_dir/summary.json"
	run pipeline_probe 0 "tests"
	[ "$status" -eq 0 ]
}

@test "CITERM stages that had already run are preserved in the aborted artefact" {
	# "Died in stage 4 with 3 green behind it" is a materially different report
	# from "died", and the information is sitting in memory when the trap fires.
	local state='declare -a stage_results=('"'"'{"name":"s1","status":"pass"}'"'"' '"'"'{"name":"s2","status":"fail"}'"'"')
failures=1'
	pipeline_probe 1 "tests" "$state" || true
	run jq -r '[(.total_stages|tostring), (.passed|tostring), (.failed|tostring), .stages[1].name] | join("|")' \
		"$report_dir/summary.json"
	[ "$output" = "2|1|1|s2" ]
}

@test "CITERM the aborted artefact is valid JSON when nothing has run yet" {
	# The earliest abort is the one most likely to be misread, and it is also the
	# one where stage_results does not exist yet — `set -u` would kill the trap.
	pipeline_probe 2 "startup" || true
	run jq -e '.stages == [] and .total_stages == 0' "$report_dir/summary.json"
	[ "$status" -eq 0 ]
}

@test "CITERM the aborted artefact is written even when jq is absent" {
	# setup.sh installs jq partway down vm-pipeline.sh, so an abort in the
	# pull-code phase is exactly the case where jq does not exist yet. A writer
	# that needed jq would produce nothing in the case it was built for.
	# A PATH holding only what the writer legitimately needs: date and mkdir.
	local minimal="$BATS_TEST_TMPDIR/minimal-bin"
	mkdir -p "$minimal"
	ln -sf "$(command -v date)" "$minimal/date"
	ln -sf "$(command -v mkdir)" "$minimal/mkdir"
	local probe="$BATS_TEST_TMPDIR/nojq-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'if command -v jq >/dev/null 2>&1; then echo "setup wrong: jq on PATH" >&2; exit 9; fi\n'
		printf 'REPORT_DIR=%q\n' "$report_dir"
		printf 'CI_SOURCE_COMMIT=deadbee\nCI_SOURCE_BRANCH=main\n'
		lift "$pipeline" json_str
		lift "$pipeline" write_terminal_summary
		lift "$pipeline" on_pipeline_exit
		printf 'PIPELINE_PHASE=pull-code\n'
		grep -Ex 'trap on_pipeline_exit EXIT' "$pipeline" || true
		printf 'exit 3\n'
	} >"$probe"
	# env resolves the command in the NEW PATH, so bash needs its absolute path.
	run env PATH="$minimal" "$(command -v bash)" "$probe"
	[ "$status" -eq 3 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
}

# ─── Classifying what came back ─────────────────────────────────────────────

# Runs the real classify_run_outcome() against a summary file we control.
classify() {
	local body="$1" expected_commit="$2" pipeline_exit="$3"
	local f="$BATS_TEST_TMPDIR/summary.json"
	if [ "$body" = "MISSING" ]; then rm -f "$f"; else printf '%s\n' "$body" >"$f"; fi
	local probe="$BATS_TEST_TMPDIR/classify-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		lift "$gcp" classify_run_outcome
		printf 'classify_run_outcome %q %q %q\n' "$f" "$expected_commit" "$pipeline_exit"
	} >"$probe"
	bash "$probe"
}

@test "CITERM a passing run is still reported exactly as a pass" {
	# The constraint on this whole change: nothing green may turn red.
	run classify '{"outcome":"PASS","commit":"fb79dfb","passed":12,"failed":0}' fb79dfb 0
	[ "$status" -eq 0 ]
	[ "$output" = "PASS" ]
}

@test "CITERM a pre-outcome summary still classifies from its overall field" {
	# A VM that has not picked up the new vm-pipeline.sh writes overall only.
	# Reading it as UNKNOWN would report a real pass as an abort.
	run classify '{"overall":"PASS","commit":"fb79dfb"}' fb79dfb 0
	[ "$output" = "PASS" ]
}

@test "CITERM a failing run is still reported exactly as a fail" {
	run classify '{"outcome":"FAIL","commit":"fb79dfb","failed":4}' fb79dfb 1
	[ "$output" = "FAIL" ]
}

@test "CITERM no summary at all is ABORTED, never a verdict" {
	run classify MISSING fb79dfb 2
	[ "$output" = "ABORTED" ]
	[ "$output" != "PASS" ]
	[ "$output" != "FAIL" ]
}

@test "CITERM a surviving RUNNING marker is ABORTED, not a result" {
	# The marker this run wrote before it started. Still there after collection
	# means NOTHING came back from the VM. Absence of a report is not a pass.
	run classify '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}' fb79dfb 2
	[ "$output" = "ABORTED" ]
}

@test "CITERM a report from a previous commit cannot be read as this run's" {
	# Incident 2: `5444d45 FAIL 8/12` read as the current round's result.
	run classify '{"outcome":"FAIL","commit":"5444d45","failed":4}' fb79dfb 1
	[ "$output" = "STALE" ]
}

@test "CITERM a stale PASS from another commit is STALE, never PASS" {
	# The dangerous direction: a green report belonging to a different run.
	run classify '{"outcome":"PASS","commit":"5444d45","passed":12}' fb79dfb 0
	[ "$output" = "STALE" ]
	[ "$output" != "PASS" ]
}

@test "CITERM a PASS summary does not outrank a non-zero pipeline exit" {
	# The pipeline died after writing its report. gcp-ci.sh already exits
	# non-zero here, so this changes no verdict — it stops the FILE disagreeing
	# with the exit status.
	run classify '{"outcome":"PASS","commit":"fb79dfb"}' fb79dfb 1
	[ "$output" = "FAIL" ]
}

@test "CITERM an unknown commit on either side does not manufacture staleness" {
	# `git rev-parse` can fail (shallow checkout, no repo). Unknown must mean
	# "cannot compare", not "stale" — that would turn a green run red.
	run classify '{"outcome":"PASS","commit":"unknown"}' fb79dfb 0
	[ "$output" = "PASS" ]
	run classify '{"outcome":"PASS","commit":"fb79dfb"}' unknown 0
	[ "$output" = "PASS" ]
}

# Runs the real final_exit_code().
final_exit() {
	local probe="$BATS_TEST_TMPDIR/exit-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		lift "$gcp" final_exit_code
		printf 'final_exit_code %q %q\n' "$1" "$2"
	} >"$probe"
	bash "$probe"
}

@test "CITERM a PASS still exits 0 — the only status that suspends the VM" {
	run final_exit PASS 0
	[ "$output" = "0" ]
}

@test "CITERM a FAIL keeps the pipeline's own status" {
	run final_exit FAIL 1
	[ "$output" = "1" ]
	run final_exit FAIL 124
	[ "$output" = "124" ]
}

@test "CITERM a report saying FAIL is never exited as a pass" {
	# The file and the exit status must not disagree. This is unreachable in
	# practice — vm-pipeline.sh exits its failure count — which is exactly why it
	# needs a guard rather than an assumption.
	run final_exit FAIL 0
	[ "$output" = "1" ]
	[ "$output" != "0" ]
}

@test "CITERM an aborted run exits 2 when the pipeline exited 0 without reporting" {
	# Preserves today's behaviour: a reportless exit 0 was already promoted to 2.
	run final_exit ABORTED 0
	[ "$output" = "2" ]
	run final_exit ABORTED 124
	[ "$output" = "124" ]
	run final_exit STALE 0
	[ "$output" = "2" ]
}

# ─── The local run marker ───────────────────────────────────────────────────

# Runs write_run_status() with the run identity we choose.
write_status() {
	local outcome="$1" phase="$2" note="${3:-}" exit_code="${4:-}"
	local probe="$BATS_TEST_TMPDIR/write-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\n' "$report_dir"
		printf 'RUN_COMMIT=fb79dfb\nRUN_BRANCH=fix/ci-terminal-state-honesty\n'
		printf 'RUN_STARTED_AT=%q\n' "2026-08-14T09:00:00+01:00"
		lift "$gcp" write_run_status
		printf 'write_run_status %q %q %q %q\n' "$outcome" "$phase" "$note" "$exit_code"
	} >"$probe"
	bash "$probe"
}

@test "CITERM the run marker names the commit under test before the VM is touched" {
	# Incident 2 again, from the other end: a poll during a run must see THIS
	# run's identity, not the previous round's verdict.
	write_status RUNNING "resuming-vm" "run in flight"
	run jq -r '[.outcome, .phase, .commit, .branch, .started_at] | join("|")' \
		"$report_dir/summary.json"
	[ "$output" = "RUNNING|resuming-vm|fb79dfb|fix/ci-terminal-state-honesty|2026-08-14T09:00:00+01:00" ]
}

@test "CITERM the run marker is valid JSON and carries the time it was written" {
	write_status ABORTED "pipeline" "died" 2
	run jq -e '.written_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$report_dir/summary.json"
	[ "$status" -eq 0 ]
	run jq -r '.exit_code | tostring' "$report_dir/summary.json"
	[ "$output" = "2" ]
}

@test "CITERM a collected report is stamped as collected, so freshness is readable" {
	# A summary.json with no collected_at is one somebody's previous run left
	# lying there. The stamp is what makes the difference machine-checkable.
	printf '{"overall":"PASS","commit":"fb79dfb","passed":12}\n' >"$report_dir/summary.json"
	local probe="$BATS_TEST_TMPDIR/stamp-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\n' "$report_dir"
		lift "$gcp" stamp_collected_summary
		printf 'stamp_collected_summary\n'
	} >"$probe"
	run bash "$probe"
	[ "$status" -eq 0 ]
	run jq -e '.collected_at != null and .outcome == "PASS" and .passed == 12' \
		"$report_dir/summary.json"
	[ "$status" -eq 0 ]
}

# ─── Reading the state back ─────────────────────────────────────────────────

# Runs print_local_run_status() at a chosen wall-clock instant.
read_status() {
	local now_epoch="$1"
	local probe="$BATS_TEST_TMPDIR/read-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nTIMEOUT_MINUTES=180\n' "$report_dir"
		lift "$gcp" print_local_run_status
		printf 'print_local_run_status %q %q\n' "$report_dir/summary.json" "$now_epoch"
	} >"$probe"
	bash "$probe"
}

@test "CITERM an empty report directory says so instead of staying silent" {
	rm -f "$report_dir/summary.json"
	run read_status "$(date +%s)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"none collected"* ]]
}

@test "CITERM a RUNNING marker older than the run fence is called unfinished" {
	# A SIGKILLed run leaves RUNNING behind with no trap to convert it. Age is
	# what tells a reader that "in flight" is a lie.
	local started stale_now
	started="2026-08-14T09:00:00+00:00"
	stale_now=$(( $(date -d "$started" +%s) + 4 * 3600 ))
	printf '{"outcome":"RUNNING","commit":"fb79dfb","branch":"b","started_at":"%s"}\n' \
		"$started" >"$report_dir/summary.json"
	run read_status "$stale_now"
	[[ "$output" == *"did not finish"* ]]
	[[ "$output" != *"a run is in flight"* ]]
}

@test "CITERM a fresh RUNNING marker is reported as in flight, not as a verdict" {
	local started fresh_now
	started="2026-08-14T09:00:00+00:00"
	fresh_now=$(( $(date -d "$started" +%s) + 120 ))
	printf '{"outcome":"RUNNING","commit":"fb79dfb","branch":"b","started_at":"%s"}\n' \
		"$started" >"$report_dir/summary.json"
	run read_status "$fresh_now"
	[[ "$output" == *"in flight"* ]]
	[[ "$output" == *"not a verdict"* ]]
}

@test "CITERM the report line dates its own claim" {
	# Incident 3: any state read without a timestamp beside it is a claim about
	# the past presented as the present.
	printf '{"outcome":"PASS","commit":"fb79dfb","branch":"main","collected_at":"2026-08-14T10:11:12+01:00"}\n' \
		>"$report_dir/summary.json"
	run read_status "$(date +%s)"
	[[ "$output" == *"PASS for main@fb79dfb"* ]]
	[[ "$output" == *"2026-08-14T10:11:12+01:00"* ]]
}

# ─── Wiring: the guards have to be reached, not just exist ──────────────────

@test "CITERM the report directory is rotated at run START, not at collection" {
	# Rotating at collection leaves the previous round's verdict readable for the
	# entire duration of the new run. That window is incident 2.
	local body rotate_line pipeline_line collect_line
	body="$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	rotate_line="$(printf '%s\n' "$body" | grep -n '^[[:space:]]*rotate_reports$' | head -1 | cut -d: -f1)"
	pipeline_line="$(printf '%s\n' "$body" | grep -n 'Running pipeline on VM' | head -1 | cut -d: -f1)"
	collect_line="$(printf '%s\n' "$body" | grep -n 'Collecting reports' | head -1 | cut -d: -f1)"
	[ -n "$rotate_line" ]
	[ -n "$pipeline_line" ]
	[ -n "$collect_line" ]
	[ "$rotate_line" -lt "$pipeline_line" ]
	[ "$rotate_line" -lt "$collect_line" ]
}

@test "CITERM the run marker is written before the VM's state is queried" {
	# The earliest failures — auth expired, VM absent, lock held — happen before
	# anything else runs. They must leave a record too.
	local body marker_line status_line trap_line
	body="$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	marker_line="$(printf '%s\n' "$body" | grep -n 'set_run_phase' | head -1 | cut -d: -f1)"
	status_line="$(printf '%s\n' "$body" | grep -n 'status="\$(vm_status)"' | head -1 | cut -d: -f1)"
	# The trap is what turns that marker into a terminal state if the run dies.
	# Unwired, every function below still works and nothing else notices.
	trap_line="$(printf '%s\n' "$body" | grep -n 'trap run_exit_trap EXIT' | head -1 | cut -d: -f1)"
	[ -n "$marker_line" ]
	[ -n "$status_line" ]
	[ -n "$trap_line" ]
	[ "$marker_line" -lt "$status_line" ]
	[ "$trap_line" -lt "$status_line" ]
}

@test "CITERM the run exit trap converts a leftover RUNNING marker to ABORTED" {
	# End to end on the real trap: a run killed mid-flight must not leave
	# "RUNNING" on disk to be read as "still going" tomorrow.
	printf '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}\n' \
		>"$report_dir/summary.json"
	local probe="$BATS_TEST_TMPDIR/trap-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\nGCP_CI_HOLDS_LOCK=0\n' "$report_dir"
		printf 'RUN_COMMIT=fb79dfb\nRUN_BRANCH=b\nRUN_STARTED_AT=t\nRUN_PHASE=pipeline\n'
		lift "$gcp" write_run_status
		lift "$gcp" lock_release
		lift "$gcp" final_exit_code
		lift "$gcp" run_exit_trap
		printf 'trap run_exit_trap EXIT\nexit 2\n'
	} >"$probe"
	run bash "$probe"
	[ "$status" -eq 2 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
}

@test "CITERM the run exit trap preserves a zero exit status" {
	# Same class of bug as lock_release's: a failing last command in an EXIT trap
	# replaces the status the script asked for. 8/8 green, exit 1.
	printf '{"outcome":"PASS","commit":"fb79dfb"}\n' >"$report_dir/summary.json"
	local probe="$BATS_TEST_TMPDIR/trap-zero-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\nGCP_CI_HOLDS_LOCK=0\n' "$report_dir"
		printf 'RUN_COMMIT=fb79dfb\nRUN_BRANCH=b\nRUN_STARTED_AT=t\nRUN_PHASE=report\n'
		lift "$gcp" write_run_status
		lift "$gcp" lock_release
		lift "$gcp" final_exit_code
		lift "$gcp" run_exit_trap
		printf 'trap run_exit_trap EXIT\nexit 0\n'
	} >"$probe"
	run bash "$probe"
	[ "$status" -eq 0 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "PASS" ]
}

# ─── Killed runs: the status and the file must say the same thing ───────────
#
# The two tests above drive the trap through `exit N`, where `$?` at trap entry
# carries the status the script asked for. A SIGNAL does not work like that:
# bash runs the EXIT trap, but `$?` is 0, because the shell was not executing a
# failing command when it was told to die. The trap therefore recorded ABORTED
# and exited on that 0 — the file and the status disagreeing, which is what
# final_exit_code exists to prevent, failing toward "everything is fine".
#
# Measured here on 2026-08-14, bash 5.x, so the tests below assert what bash
# actually does rather than what it is assumed to do:
#
#   SIGTERM / SIGHUP — the trap runs, then bash RE-RAISES the signal, so the
#                      process reports 143 / 129 whatever the trap exits with.
#                      The trap's chosen status never reaches the caller.
#   SIGINT           — the trap runs and its `exit` status IS the process's.
#                      This is the reachable hole: Ctrl-C on `make ci-gcp` wrote
#                      ABORTED and exited 0. An operator's most ordinary action.
#
# Both are covered. Asserting only the SIGTERM case would have gone green on the
# broken code, since 143 is already non-zero.

# Drives the REAL trap under a REAL signal and leaves the process's status in
# $probe_status. The subject is killed BY PID — never by pattern, which on this
# harness matches the shell issuing the kill.
signal_probe() {
	local sig="$1" marker="$2" omit="${3:-}"
	printf '%s\n' "$marker" >"$report_dir/summary.json"
	local probe="$BATS_TEST_TMPDIR/signal-probe.sh"
	local ready="$BATS_TEST_TMPDIR/probe-armed"
	rm -f "$ready"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\nGCP_CI_HOLDS_LOCK=0\n' "$report_dir"
		printf 'RUN_COMMIT=fb79dfb\nRUN_BRANCH=b\nRUN_STARTED_AT=t\nRUN_PHASE=pipeline\n'
		lift "$gcp" write_run_status
		lift "$gcp" lock_release
		# Omitted on purpose by one test below, to prove the trap still refuses to
		# exit 0 when the function it asks for is not there to answer.
		[ "$omit" = "no-final-exit-code" ] || lift "$gcp" final_exit_code
		lift "$gcp" run_exit_trap
		# Armed, THEN blocked: a fixed sleep before the kill races the trap's
		# installation, and a probe signalled before the trap is armed dies
		# silently with the marker untouched — a green test proving nothing.
		printf 'trap run_exit_trap EXIT\ntouch %q\nsleep 10\n' "$ready"
	} >"$probe"

	bash "$probe" >/dev/null 2>&1 &
	local pid=$! waited=0
	while [ ! -f "$ready" ] && [ "$waited" -lt 100 ]; do
		sleep 0.05
		waited=$((waited + 1))
	done
	[ -f "$ready" ] || {
		kill "$pid" 2>/dev/null || true
		echo "probe never armed its trap" >&2
		return 1
	}
	kill -"$sig" "$pid"
	probe_status=0
	wait "$pid" || probe_status=$?
	return 0
}

@test "CITERM a run interrupted with Ctrl-C does not exit 0 while its report says ABORTED" {
	# The headline defect. `make ci-gcp`, Ctrl-C, exit 0 — a killed run that any
	# wrapper, CI step or `&&` chain reads as a clean success, with ABORTED
	# sitting in the file next to it.
	signal_probe INT '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}'
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
	[ "$probe_status" -ne 0 ]
	# Not merely non-zero: the same number the file records, so a reader of
	# either one reaches the same conclusion.
	run jq -r '.exit_code' "$report_dir/summary.json"
	[ "$output" = "$probe_status" ]
	# The status an abort with no failure of its own is worth, per final_exit_code.
	[ "$probe_status" -eq 2 ]
}

@test "CITERM a run killed by SIGTERM records the abort with a non-zero status" {
	# bash re-raises SIGTERM after the trap, so the process reports 143 no matter
	# what the trap exits with — the caller was never going to be lied to here.
	# The FILE was: it recorded `ABORTED` with `exit_code: 0`, the same lie in the
	# same place, waiting for anyone who reads the report instead of the status.
	signal_probe TERM '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}'
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
	[ "$probe_status" -ne 0 ]
	run jq -r '.exit_code' "$report_dir/summary.json"
	[ "$output" != "0" ]
	[ "$output" = "2" ]
}

@test "CITERM an abort recorded before the signal is still not exited 0" {
	# The window between cmd_run writing its own ABORTED (the STALE branch does
	# exactly this) and reaching `exit "$final_exit"`. A signal landing in there
	# finds a terminal marker rather than RUNNING, so a guard written only for
	# RUNNING would step past it and exit 0 on a report that says ABORTED.
	signal_probe INT '{"outcome":"ABORTED","commit":"fb79dfb","phase":"collect"}'
	[ "$probe_status" -ne 0 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
}

@test "CITERM a PASS on disk is still exited 0 when a signal arrives" {
	# The other direction, and the one that costs money if it is wrong: a run
	# that finished and passed must not be turned red by a signal arriving during
	# its own teardown. Only a non-terminal or aborted report may raise the status.
	signal_probe INT '{"outcome":"PASS","commit":"fb79dfb","passed":12}'
	[ "$probe_status" -eq 0 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "PASS" ]
}

@test "CITERM the trap keeps a failing run's own exit status instead of overwriting it" {
	# ABORTED must not flatten every death to 2. A run that died with 1, or with
	# timeout's 124, is more informative than the generic abort code, and
	# final_exit_code already says so — this proves the trap asks it rather than
	# hardcoding a number of its own.
	printf '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}\n' \
		>"$report_dir/summary.json"
	local probe="$BATS_TEST_TMPDIR/trap-124-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nVM_NAME=signalloom-ci\nGCP_CI_HOLDS_LOCK=0\n' "$report_dir"
		printf 'RUN_COMMIT=fb79dfb\nRUN_BRANCH=b\nRUN_STARTED_AT=t\nRUN_PHASE=pipeline\n'
		lift "$gcp" write_run_status
		lift "$gcp" lock_release
		lift "$gcp" final_exit_code
		lift "$gcp" run_exit_trap
		printf 'trap run_exit_trap EXIT\nexit 124\n'
	} >"$probe"
	run bash "$probe"
	[ "$status" -eq 124 ]
	run jq -r '.exit_code' "$report_dir/summary.json"
	[ "$output" = "124" ]
}

@test "CITERM the trap decides its status with final_exit_code, not a second rule" {
	# There is one place the run's exit status is decided. A trap that grew its
	# own `if ((rc == 0)); then rc=2; fi` would pass every test above — it behaves
	# identically today — and drift from the normal path the first time either
	# changed.
	#
	# COMMENTS ARE STRIPPED FIRST, and that is the whole point: the first version
	# of this test matched the function body as one string, and the trap's own
	# comment says "final_exit_code" in prose. It went green against a mutant that
	# had inlined the rule, because a comment is not a call. Mutation testing
	# caught it; the grep -v is the fix.
	local body
	body="$(sed -n '/^run_exit_trap() {/,/^}/p' "$gcp" | grep -v '^[[:space:]]*#')"
	[[ "$body" == *"final_exit_code "* ]]
}

@test "CITERM the trap still refuses to exit 0 if final_exit_code cannot answer" {
	# A status writer must never be the thing that fails a run — but it must not
	# be the thing that PASSES one either. If the helper is renamed away from
	# under the trap, the fallback holds the invariant: an abort is not a success.
	signal_probe INT '{"outcome":"RUNNING","commit":"fb79dfb","phase":"pipeline"}' no-final-exit-code
	[ "$probe_status" -ne 0 ]
	run jq -r '.outcome' "$report_dir/summary.json"
	[ "$output" = "ABORTED" ]
}

@test "CITERM a failed run still leaves the VM running for debugging" {
	# Deliberate and correct: a failed run needs a live VM. This change adds a
	# durable record of the failure; it must not take the VM away.
	local body
	body="$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	[[ "$body" == *"VM left running for debugging"* ]]
	# And the suspend stays gated on a zero exit — nothing else may suspend.
	local suspend_line guard_line
	suspend_line="$(printf '%s\n' "$body" | grep -n 'instances suspend' | head -1 | cut -d: -f1)"
	guard_line="$(printf '%s\n' "$body" | grep -n 'final_exit == 0' | tail -1 | cut -d: -f1)"
	[ -n "$suspend_line" ]
	[ -n "$guard_line" ]
	[ "$guard_line" -lt "$suspend_line" ]
}

@test "CITERM the verdict is named as surviving the VM being suspended" {
	# SUSPENDED is the success state, so suspending a failed VM to stop the cost
	# erases the only signal there was. Point at the thing that does survive.
	local body
	body="$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	[[ "$body" == *"Suspending does not erase this"* ]]
}

@test "CITERM status dates its answer instead of implying the present" {
	local body
	body="$(awk '/^cmd_status\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	[[ "$body" == *"Observed:"* ]]
	# lastStartTimestamp was the query operators had to reach for by hand to tell
	# an aborted run from a passing one. Print it.
	[[ "$body" == *"lastStartTimestamp"* ]]
	[[ "$body" == *"print_local_run_status"* ]]
}

@test "CITERM status tells an abort apart from a pass on an identically suspended VM" {
	# Incident 1, end to end on the real script with gcloud stubbed. Both cases
	# below are a SUSPENDED VM — the state after a clean pass AND the state after
	# an operator suspends an aborted run by hand to stop the cost. If these two
	# invocations print the same thing, the defect is back.
	local stub="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stub"
	cat >"$stub/gcloud" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *lastStartTimestamp*) echo "2026-08-13T20:41:07.113-07:00" ;;
  *) echo "SUSPENDED" ;;
esac
STUB
	chmod +x "$stub/gcloud"

	printf '{"outcome":"ABORTED","phase":"pull-code","commit":"5444d45","branch":"feat/x","written_at":"2026-08-13T21:02:11+01:00"}\n' \
		>"$report_dir/summary.json"
	run env PATH="$stub:$PATH" GCP_CI_REPORT_DIR="$report_dir" bash "$gcp" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"ABORTED for feat/x@5444d45"* ]]
	[[ "$output" == *"phase: pull-code"* ]]
	local aborted_output="$output"

	printf '{"outcome":"PASS","commit":"fb79dfb","branch":"main","passed":12,"collected_at":"2026-08-14T02:14:55+01:00"}\n' \
		>"$report_dir/summary.json"
	run env PATH="$stub:$PATH" GCP_CI_REPORT_DIR="$report_dir" bash "$gcp" status
	[[ "$output" == *"PASS for main@fb79dfb"* ]]
	[[ "$output" != *"ABORTED"* ]]
	[ "$output" != "$aborted_output" ]
}

@test "CITERM no two stages share a numbered suffix" {
	# 1b, 1c, 1d, 1e and 1f exist because inserting a stage must stay cheap. That
	# only holds while a suffix names exactly ONE stage: openreports-convert.sh
	# keys on the report FILE, so two stages numbered alike are an ambiguity that
	# the next person to touch this resolves by guessing. It has already happened
	# once — the node-image and terminal-state stages were written in parallel
	# and both took 1e.
	local dupes
	dupes="$(grep -oE '^[[:space:]]+"stage[^"]+"' "$pipeline" | tr -d ' "' \
		| sed -E 's/^(stage[0-9]+[a-z]?)-.*/\1/' | sort | uniq -d)"
	[ -z "$dupes" ] || {
		echo "stages sharing a suffix: $dupes" >&2
		return 1
	}
}

@test "CITERM every TAP stage report is registered in the stage map" {
	# A stage whose report file is not in openreports-convert.sh's map still
	# RUNS, and its results are silently dropped from the OpenReports output —
	# the run goes green having reported less than it tested. That is the failure
	# mode a careless merge of this file produces, so it gets a guard rather than
	# a convention.
	local convert="${repo_root}/scripts/ci/openreports-convert.sh"
	local f
	for f in $(grep -oE '^[[:space:]]+"stage[^"]+\.(tap|json)"' "$pipeline" | tr -d ' "'); do
		grep -Fq "file: '${f}'" "$convert" || {
			echo "stage report not registered in the stage map: $f" >&2
			return 1
		}
	done
}

@test "CITERM no existing stage report filename was renamed" {
	# openreports-convert.sh maps report FILES to parsers by name; 1b, 1c, 1d and
	# 6b are suffixes for exactly that reason. Renaming one silently drops a
	# stage from the report.
	local f
	for f in stage1-static.tap stage1b-dashboard-unit.xml stage1e-node-images.tap \
		stage2-api.xml stage3-fakes.xml stage8-browser.xml stage8b-smoke.xml \
		stages.json summary.json wait-stats.txt; do
		grep -Fq "$f" "$pipeline" || {
			echo "missing report filename: $f" >&2
			return 1
		}
	done
}
