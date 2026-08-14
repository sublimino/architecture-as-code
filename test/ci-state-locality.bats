#!/usr/bin/env bats
#
# test/ci-terminal-state.bats fixed the ambiguity WITHIN a report directory: a
# run now writes RUNNING before it touches the VM, rotates the previous
# generation out of the way, and ends on an explicit PASS / FAIL / ABORTED /
# STALE. Those tests still pass and nothing here weakens them.
#
# The ambiguity did not disappear, it MOVED. REPORT_DIR is <checkout>/ci-reports
# and this repo now has a dozen checkouts, so on 2026-08-14:
#
#   1. The main checkout's ci-reports-2/summary.json said `d574d7d PASS 11/11`
#      from the previous day, while the run everyone cared about had finished an
#      hour earlier in a lane worktree. That artefact was honest — main did
#      produce it — and was still the wrong answer. Two agents saw it
#      independently and each assumed their own tooling was misreading.
#   2. A RUNNING marker in the main checkout was read as stranded. It was not:
#      two `gcp-ci.sh run` processes were mid-pipeline from that very directory.
#      The marker named its pid, in prose, inside the `note` field, where no
#      tool could reach it. The classifier was never fooled; a human was.
#
# So the two guards here are: a report must say which checkout produced it and
# whether a fresher one exists elsewhere, and a RUNNING marker must be
# separable from an abandoned one by asking the operating system, not by
# guessing from a timestamp. Functions are lifted verbatim out of gcp-ci.sh
# with sed, as the sibling suites do, so a reworded implementation cannot
# silently stop being covered. No gcloud, no VM, no network.

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	gcp="${repo_root}/scripts/ci/gcp-ci.sh"
	report_dir="$BATS_TEST_TMPDIR/ci-reports"
	mkdir -p "$report_dir"

	# A real git repo, because the sibling scan enumerates checkouts with
	# `git worktree list` and the STALE guard compares against a real HEAD.
	#
	# --no-gpg-sign is not tidiness. With commit.gpgsign=true in a developer's
	# global config, the fixture commit launches pinentry on a tty bats does not
	# have and blocks until something kills it — a hang with no error message,
	# in setup(), i.e. on every test in the file at once.
	fake_root="$BATS_TEST_TMPDIR/checkout"
	mkdir -p "$fake_root"
	git -C "$fake_root" init -q -b main
	git -C "$fake_root" -c user.email=t@t -c user.name=t \
		commit -q --allow-empty --no-gpg-sign -m init
	head_commit="$(git -C "$fake_root" rev-parse --short HEAD)"
}

teardown() {
	[[ -n "${spawned_pid:-}" ]] && kill "$spawned_pid" 2>/dev/null
	return 0
}

# Lift a function verbatim out of a script.
lift() {
	sed -n "/^$2() {/,/^}/p" "$1"
}

# Everything cmd_state needs, and nothing it does not. REPORT_DIR and REPO_ROOT
# are the two knobs; the rest is the real implementation.
state_probe() {
	local rdir="${1:-$report_dir}" root="${2:-$fake_root}"
	local probe="$BATS_TEST_TMPDIR/state-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nREPO_ROOT=%q\n' "$rdir" "$root"
		printf 'REPORT_FILENAME=signalloom-ci-report.yaml\nVM_NAME=signalloom-ci\n'
		lift "$gcp" proc_start_epoch
		lift "$gcp" marker_process_state
		lift "$gcp" summary_epoch
		lift "$gcp" newer_sibling_reports
		lift "$gcp" print_sibling_reports
		lift "$gcp" classify_run_outcome
		lift "$gcp" final_exit_code
		lift "$gcp" cmd_state
		printf 'cmd_state\n'
	} >"$probe"
	bash "$probe"
}

# A summary.json with whatever fields the case under test needs.
write_summary() {
	local dir="$1"; shift
	mkdir -p "$dir"
	jq -n "$@" '$ARGS.named' >"${dir}/summary.json"
}

# A live process we own, plus its pid. Used instead of a stub because the guard
# under test is "ask the operating system", and a stubbed ps would test nothing.
#
# All three of bats' file descriptors are closed on the child. A background
# process that inherits them keeps them open, and bats blocks reading its own
# output until the process exits — which is a 300-second hang that looks exactly
# like a test that is thinking hard about something.
spawn_live() {
	sleep 60 </dev/null >/dev/null 2>&1 3>&- &
	spawned_pid=$!
}

# ─── It says which file it read ─────────────────────────────────────────────
#
# The whole point. The data was never the problem.

@test "CISTATE names the report file it read, by absolute path" {
	write_summary "$report_dir" --arg outcome PASS --arg commit "$head_commit"
	run state_probe
	[[ "${lines[0]}" == "Report:   ${report_dir}/summary.json" ]]
	[[ "${lines[0]}" == "Report:   /"* ]]
}

@test "CISTATE names the checkout and its HEAD, so 'which tree' is answered too" {
	write_summary "$report_dir" --arg outcome PASS --arg commit "$head_commit"
	run state_probe
	[[ "${lines[1]}" == "Checkout: ${fake_root}  (HEAD main@${head_commit})" ]]
}

@test "CISTATE a relative GCP_CI_REPORT_DIR is anchored at the checkout, not at cwd" {
	# The Makefile passes GCP_CI_REPORT_DIR=ci-reports-2. Resolved against $PWD
	# it wrote reports wherever the caller happened to be standing — cwd drift
	# that has bitten this repo repeatedly. Run the REAL script from a
	# guaranteed-wrong cwd and check where it looks.
	cd "$BATS_TEST_TMPDIR"
	run env GCP_CI_REPORT_DIR=ci-reports-2 bash "$gcp" state
	[[ "${lines[0]}" == "Report:   ${repo_root}/ci-reports-2/summary.json" ]]
	# and specifically NOT under the cwd we ran from
	[[ "${lines[0]}" != *"$BATS_TEST_TMPDIR"* ]]
}

# ─── STALE: the report describes a different commit ─────────────────────────

@test "CISTATE a summary stamped a different commit than HEAD is reported STALE" {
	write_summary "$report_dir" --arg outcome PASS --arg commit deadbee
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"Verdict:  STALE"* ]]
	[[ "$output" == *"stamped deadbee"* ]]
	[[ "$output" == *"HEAD here is ${head_commit}"* ]]
	# A stale PASS must never present as a pass.
	[[ "$output" != *"Verdict:  PASS"* ]]
}

@test "CISTATE the STALE verdict comes from classify_run_outcome, not a second opinion" {
	# classify_run_outcome is correct and is the reason no tooling was fooled by
	# any of this. If cmd_state ever grows its own commit comparison, this is the
	# test that has to be deleted to make it pass — which is the alarm.
	local body="$BATS_TEST_TMPDIR/cmd_state.sh"
	sed -n '/^cmd_state() {/,/^}/p' "$gcp" >"$body"
	run grep -c 'classify_run_outcome "' "$body"
	[ "$output" -eq 1 ]
	# No hand-rolled equivalent of the STALE branch living alongside it.
	run grep -Ec '\$commit"? *[!=]= *"?\$head_commit' "$body"
	[ "$output" -eq 0 ]
}

# ─── Exit codes match outcomes ──────────────────────────────────────────────

@test "CISTATE exits 0 for PASS at HEAD" {
	write_summary "$report_dir" --arg outcome PASS --arg commit "$head_commit" \
		--argjson passed 15 --argjson total_stages 15
	run state_probe
	[ "$status" -eq 0 ]
	[[ "$output" == *"Verdict:  PASS"* ]]
	[[ "$output" == *"Stages:   15 passed, 0 failed, of 15"* ]]
}

@test "CISTATE exits non-zero for FAIL" {
	write_summary "$report_dir" --arg outcome FAIL --arg commit "$head_commit" \
		--argjson passed 11 --argjson failed 1 --argjson total_stages 12
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"Verdict:  FAIL"* ]]
}

@test "CISTATE exits non-zero for ABORTED" {
	write_summary "$report_dir" --arg outcome ABORTED --arg commit "$head_commit"
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"Verdict:  ABORTED"* ]]
}

@test "CISTATE an absent summary is a non-verdict, not a silent zero" {
	rm -f "${report_dir}/summary.json"
	run state_probe
	[ "$status" -eq 2 ]
	[[ "$output" == *"Verdict:  NONE"* ]]
	[[ "$output" == *"no run has finished in this checkout"* ]]
	# It still says which file it looked for.
	[[ "${lines[0]}" == "Report:   ${report_dir}/summary.json" ]]
}

# ─── RUNNING is reported honestly, and liveness decides which honesty ───────

@test "CISTATE a RUNNING marker whose process is alive says IN FLIGHT" {
	spawn_live
	write_summary "$report_dir" --arg outcome RUNNING --arg commit "$head_commit" \
		--arg phase pipeline --argjson pid "$spawned_pid" \
		--arg host "$(hostname -s)" --arg started_at "$(date -Iseconds)"
	run state_probe
	[[ "$output" == *"RUNNING — a run is IN FLIGHT"* ]]
	[[ "$output" == *"pid ${spawned_pid} on $(hostname -s) is alive"* ]]
	[[ "$output" == *"Not a verdict"* ]]
	# In flight is still not a pass: a script must not proceed on it.
	[ "$status" -ne 0 ]
}

@test "CISTATE a RUNNING marker whose process is gone is ABORTED, not in-flight" {
	# This is the stranded marker the fix exists for. It must not be able to
	# claim a run is in flight when the run is dead.
	#
	# The only way to reach this state in production is SIGKILL: `trap
	# run_exit_trap EXIT` is armed before the VM is touched, and bash runs an
	# EXIT trap on TERM, INT and HUP as well as on a normal exit (verified — and
	# timeout(1) sends TERM first, so even the outer fence converts the marker).
	# SIGKILL cannot be caught by anyone, so `timeout -k` past its grace period,
	# an OOM kill or `kill -9` leaves RUNNING on disk forever. Impossible is not
	# on the menu; self-evident is, and this is it.
	sleep 60 </dev/null >/dev/null 2>&1 3>&- &
	local dead=$!
	kill "$dead" 2>/dev/null
	wait "$dead" 2>/dev/null || true
	write_summary "$report_dir" --arg outcome RUNNING --arg commit "$head_commit" \
		--arg phase pipeline --argjson pid "$dead" \
		--arg host "$(hostname -s)" --arg started_at "$(date -Iseconds)"
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"Verdict:  ABORTED"* ]]
	[[ "$output" == *"pid ${dead} on $(hostname -s) is gone"* ]]
	[[ "$output" != *"IN FLIGHT"* ]]
}

@test "CISTATE a live pid that started after the marker is a recycled number, not the run" {
	# A pid alone proves nothing. Without this, an old marker naming a number
	# some unrelated process now holds reads as "still running" forever — the
	# original defect, reintroduced by its own fix.
	spawn_live
	write_summary "$report_dir" --arg outcome RUNNING --arg commit "$head_commit" \
		--arg phase pipeline --argjson pid "$spawned_pid" \
		--arg host "$(hostname -s)" \
		--arg started_at "$(date -Iseconds -d '2 hours ago')"
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"Verdict:  ABORTED"* ]]
	[[ "$output" == *"different"*"process reusing the number"* ]]
	[[ "$output" != *"IN FLIGHT"* ]]
}

@test "CISTATE a RUNNING marker written on another host says so instead of guessing" {
	write_summary "$report_dir" --arg outcome RUNNING --arg commit "$head_commit" \
		--arg phase pipeline --argjson pid 4120234 \
		--arg host somewhere-else --arg started_at "$(date -Iseconds)"
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"written on 'somewhere-else'"* ]]
	[[ "$output" == *"cannot be checked from here"* ]]
	# It must not claim the run is alive OR dead — it cannot see either.
	[[ "$output" != *"is alive"* ]]
	[[ "$output" != *"is gone"* ]]
	[[ "$output" != *"IN FLIGHT"* ]]
}

@test "CISTATE a RUNNING marker with no pid admits liveness is uncheckable" {
	# Every marker written before this change looks like this, including the one
	# in the main checkout right now. Claiming a verdict about it would be the
	# same class of lie in a new place.
	write_summary "$report_dir" --arg outcome RUNNING --arg commit "$head_commit" \
		--arg phase pipeline --arg started_at "$(date -Iseconds)" \
		--arg note "run in flight (pid 4120234 on fortuna); this is not a verdict"
	run state_probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"no usable pid recorded"* ]]
	[[ "$output" != *"IN FLIGHT"* ]]
}

# ─── Provenance: which checkout produced this? ──────────────────────────────

@test "CISTATE the run marker records pid, host and origin as fields, not prose" {
	local probe="$BATS_TEST_TMPDIR/write-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nREPO_ROOT=%q\nVM_NAME=signalloom-ci\n' "$report_dir" "$fake_root"
		printf 'RUN_COMMIT=%q\nRUN_BRANCH=main\nRUN_STARTED_AT=%q\n' \
			"$head_commit" "2026-08-14T21:49:29+01:00"
		lift "$gcp" write_run_status
		printf 'write_run_status RUNNING pipeline "in flight"\n'
	} >"$probe"
	bash "$probe"
	run jq -r '[(.pid|type), (.host|type), .origin] | join("|")' "${report_dir}/summary.json"
	[ "$output" = "number|string|${fake_root}" ]
	# The pid recorded is the writer's own, which is what makes it checkable.
	run jq -e '.pid > 0' "${report_dir}/summary.json"
	[ "$status" -eq 0 ]
}

@test "CISTATE a collected report is stamped with the checkout that collected it" {
	# Collection OVERWRITES summary.json with the VM's copy, which knows nothing
	# about the checkout that asked for the run. Without this stamp the collected
	# report — the one that actually carries the verdict — has no provenance.
	printf '{"overall":"PASS","commit":"%s","passed":15}\n' "$head_commit" >"${report_dir}/summary.json"
	local probe="$BATS_TEST_TMPDIR/stamp-probe.sh"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'REPORT_DIR=%q\nREPO_ROOT=%q\nVM_NAME=signalloom-ci\n' "$report_dir" "$fake_root"
		lift "$gcp" stamp_collected_summary
		printf 'stamp_collected_summary\n'
	} >"$probe"
	bash "$probe"
	run jq -r '.origin' "${report_dir}/summary.json"
	[ "$output" = "$fake_root" ]
	run jq -e '.collected_at != null and .outcome == "PASS" and .passed == 15' "${report_dir}/summary.json"
	[ "$status" -eq 0 ]
}

@test "CISTATE a report produced by a different checkout announces itself" {
	write_summary "$report_dir" --arg outcome PASS --arg commit "$head_commit" \
		--arg origin /somewhere/else/osramp-demo
	run state_probe
	[[ "$output" == *"Origin:   /somewhere/else/osramp-demo — a DIFFERENT checkout produced this report"* ]]
}

@test "CISTATE a report with no origin field says provenance is unknown, not 'ours'" {
	write_summary "$report_dir" --arg outcome PASS --arg commit "$head_commit"
	run state_probe
	[[ "$output" == *"Origin:   not recorded"* ]]
	[[ "$output" != *"Origin:   this checkout"* ]]
}

# ─── Cross-checkout staleness is announced, not silent ──────────────────────

@test "CISTATE a fresher report in another checkout is named" {
	# The exact 2026-08-14 shape: this checkout holds yesterday's verdict, the
	# real one is in a worktree. Silence here is what made two agents doubt
	# their own tooling instead of the artefact.
	local wt="$BATS_TEST_TMPDIR/lane"
	git -C "$fake_root" worktree add -q -b lane "$wt"
	mkdir -p "$fake_root/ci-reports" "$wt/ci-reports"
	write_summary "$fake_root/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-13T21:05:00+01:00"
	write_summary "$wt/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-14T21:43:16+01:00"
	run state_probe "$fake_root/ci-reports" "$fake_root"
	[[ "$output" == *"NEWER ELSEWHERE"* ]]
	[[ "$output" == *"${wt}/ci-reports/summary.json"* ]]
	[[ "$output" == *"not the whole story"* ]]
}

@test "CISTATE an OLDER report elsewhere is not announced, so the line keeps meaning something" {
	local wt="$BATS_TEST_TMPDIR/lane"
	git -C "$fake_root" worktree add -q -b lane "$wt"
	mkdir -p "$fake_root/ci-reports" "$wt/ci-reports"
	write_summary "$fake_root/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-14T21:43:16+01:00"
	write_summary "$wt/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-13T21:05:00+01:00"
	run state_probe "$fake_root/ci-reports" "$fake_root"
	[[ "$output" != *"NEWER ELSEWHERE"* ]]
}

@test "CISTATE the sibling comparison uses the report's own time, not the file's mtime" {
	# mtime is set by whatever last touched the file, so a copy, an rsync or a
	# tar extraction re-dates a report it did not produce. Comparing mtimes
	# would make the freshest COPY win over the freshest RUN.
	local wt="$BATS_TEST_TMPDIR/lane"
	git -C "$fake_root" worktree add -q -b lane "$wt"
	mkdir -p "$fake_root/ci-reports" "$wt/ci-reports"
	write_summary "$fake_root/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-14T21:43:16+01:00"
	write_summary "$wt/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-13T21:05:00+01:00"
	# The stale one is now, by a clear margin, the most recently WRITTEN file on
	# disk. The margin is the point: mtime has one-second granularity, so two
	# fixtures created back to back are indistinguishable by mtime and a test
	# that relied on their ordering would pass under a mtime implementation too.
	touch -d "@$(( $(date +%s) + 3600 ))" "$wt/ci-reports/summary.json"
	run state_probe "$fake_root/ci-reports" "$fake_root"
	[[ "$output" != *"NEWER ELSEWHERE"* ]]
}

@test "CISTATE a checkout with no report at all is pointed at the one that has it" {
	local wt="$BATS_TEST_TMPDIR/lane"
	git -C "$fake_root" worktree add -q -b lane "$wt"
	mkdir -p "$fake_root/ci-reports" "$wt/ci-reports"
	write_summary "$wt/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-14T21:43:16+01:00"
	run state_probe "$fake_root/ci-reports" "$fake_root"
	[ "$status" -eq 2 ]
	[[ "$output" == *"Verdict:  NONE"* ]]
	[[ "$output" == *"${wt}/ci-reports/summary.json"* ]]
}

@test "CISTATE our own checkout is never listed as its own sibling" {
	mkdir -p "$fake_root/ci-reports"
	write_summary "$fake_root/ci-reports" --arg outcome PASS --arg commit "$head_commit" \
		--arg collected_at "2026-08-14T21:43:16+01:00"
	run state_probe "$fake_root/ci-reports" "$fake_root"
	[[ "$output" != *"NEWER ELSEWHERE"* ]]
}

# ─── Wiring: the command has to be reachable, not just present ──────────────

@test "CISTATE the state subcommand is dispatched and advertised" {
	run grep -Ex '  state\)       cmd_state ;;' "$gcp"
	[ "$status" -eq 0 ]
	run grep -c 'ssh|status|state|destroy' "$gcp"
	[ "$output" -eq 1 ]
	run grep -Eq '^ci-state:' "${repo_root}/Makefile"
	[ "$status" -eq 0 ]
	run grep -Eq '^ci-state-2:' "${repo_root}/Makefile"
	[ "$status" -eq 0 ]
}

@test "CISTATE state touches neither gcloud nor the lock, so it is safe mid-run" {
	# A "what happened?" command that resumed a VM or took the lock would be a
	# trap: the natural thing to type while a lane is in flight.
	run bash -c "sed -n '/^cmd_state() {/,/^}/p' '$gcp' | grep -cE 'gcloud|lock_acquire|lock_release|iap_ssh'"
	[ "$output" -eq 0 ]
}
