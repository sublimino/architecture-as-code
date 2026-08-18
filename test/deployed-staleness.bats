#!/usr/bin/env bats
#
# The defect: on 2026-08-13 a streaming fix landed across 22 commits, passed 315
# backend tests, 1657 dashboard tests and a browser harness, and was reported as
# working. The pods answering the requests predated every commit —
# supercred-demo-runner was 3h56m old and still ran the original bug. Every test
# was green and every one of them tested the SOURCE TREE.
#
# These tests drive scripts/check-deployed-staleness.sh against a fake kubectl —
# no cluster, no API server — because the outcomes worth proving are the FAILURE
# outcomes, and a real cluster that happens to be healthy today exercises none of
# them. The fakes let a stale deployment be reproduced on demand.
#
# The fakes are the same shape as test/kind-load-verified.bats and
# test/supervise-port-forward.bats so the three can be read together.
#
# The single most important property under test is that the guard CANNOT PASS
# VACUOUSLY: an unreachable cluster, a missing kubectl, a crash-looping workload
# and a failed readback must all be distinguishable from "verified matching", in
# the exit code AND in the words. A guard that reports OK when it could not look
# is worse than no guard, because it manufactures the very confidence that made
# the original incident possible.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/check-deployed-staleness.sh"
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# The real fingerprint of the current working tree, from the same library the
	# build sites and the guard both use. Computing it here rather than hardcoding
	# a digest is deliberate: it proves the guard's expected value and the value a
	# build would bake in are produced by one piece of code.
	# shellcheck source=scripts/lib/source-id.sh
	source "$root/scripts/lib/source-id.sh"
	REAL_ID="$(source_id_for supercred-demo-runner)"
	export REAL_ID

	# Knobs the fake kubectl reads. Defaults describe a healthy cluster running a
	# pod built from the current tree; each test perturbs exactly one.
	export CLUSTER_STATUS=0
	export DEPLOYMENT_STATUS=0
	export POD_NAME="supercred-demo-runner-84b564dffd-66n9s"
	# 3h56m ago — the age the incident pod actually reported. Epoch arithmetic
	# rather than `date -d '3 hours 56 minutes ago'`, because GNU date applies
	# "ago" only to the LAST unit and silently returns now+3h-56m — a FUTURE
	# timestamp, which made this fixture assert nothing.
	export POD_CREATED="$(date -u -d "@$(($(date +%s) - 14160))" +%Y-%m-%dT%H:%M:%SZ)"
	export EXEC_STATUS=0
	export MARKER_SOURCE_ID="$REAL_ID"
	export MARKER_GIT_REF="a960282"
	export MARKER_ABSENT=0
	export MARKER_GARBAGE=0

	cat >"$bin/kubectl" <<-'FAKE'
		#!/usr/bin/env bash
		# Route on the verb, ignoring -n/namespace flags the way the real client's
		# arguments happen to be ordered by the caller.
		args="$*"
		case "$args" in
		  "cluster-info"*)
		    exit "${CLUSTER_STATUS:-0}" ;;
		  *"get deployment"*)
		    exit "${DEPLOYMENT_STATUS:-0}" ;;
		  *"get pods"*)
		    # Empty POD_NAME models "Deployment exists, nothing Running".
		    [ -n "${POD_NAME:-}" ] && printf '%s %s\n' "$POD_NAME" "$POD_CREATED"
		    exit 0 ;;
		  *" exec "*)
		    # A genuine exec failure: non-zero AND no output. This is the shape the
		    # guard must NOT confuse with a missing marker file.
		    [ "${EXEC_STATUS:-0}" != 0 ] && exit "$EXEC_STATUS"
		    # The guard asks the container for `cat … || echo MARKER_ABSENT`, so a
		    # working exec against a marker-less image prints exactly this.
		    if [ "${MARKER_ABSENT:-0}" = 1 ]; then echo "MARKER_ABSENT"; exit 0; fi
		    if [ "${MARKER_GARBAGE:-0}" = 1 ]; then echo "not-a-marker"; exit 0; fi
		    printf 'workload=supercred-demo-runner\nsource_id=%s\ngit_ref=%s\n' \
		      "$MARKER_SOURCE_ID" "$MARKER_GIT_REF"
		    exit 0 ;;
		esac
		exit 0
	FAKE

	chmod +x "$bin/kubectl"
	export KUBECTL_BIN="$bin/kubectl"
	PATH="$bin:$PATH"
	export PATH
}

# ─── Green ──────────────────────────────────────────────────────────────────

@test "matching deployment verifies fresh and exits 0" {
	run "$script" supercred-demo-runner
	[ "$status" -eq 0 ]
	[[ "$output" == *"fresh"* ]]
	[[ "$output" == *"every checked workload is running the current working tree"* ]]
}

# ─── Red: the incident, reproduced ──────────────────────────────────────────

@test "stale deployment fails loudly, naming the workload and how far behind" {
	# The incident: pod built from an older tree, still serving.
	export MARKER_SOURCE_ID="0000000000000000000000000000000000000000000000000000000000000bad"
	run "$script" supercred-demo-runner
	[ "$status" -eq 1 ]
	[[ "$output" == *"supercred-demo-runner"* ]]
	[[ "$output" == *"STALE"* ]]
	# Names how far behind, in the unit a human reads off `kubectl get pods`.
	[[ "$output" == *"3h56m"* ]]
	# Shows BOTH sides, so the reader can tell drift from a broken guard.
	[[ "$output" == *"running from source"* ]]
	[[ "$output" == *"working tree is"* ]]
	[[ "$output" == *"${REAL_ID:0:12}"* ]]
	# Must never claim success alongside a failure.
	[[ "$output" != *"every checked workload is running the current working tree"* ]]
}

@test "stale deployment reports commit distance when the baked ref is a real commit" {
	export MARKER_SOURCE_ID="0000000000000000000000000000000000000000000000000000000000000bad"
	export MARKER_GIT_REF="$(git -C "$root" rev-parse --short HEAD~3)"
	# Derived, not hard-coded. `HEAD~3` is three FIRST-PARENT steps back, which
	# equals three commits only on a linear history — and this branch merges
	# constantly. The guard counts with `rev-list --count`, so the moment a merge
	# commit lands, `HEAD~3` is three steps but five commits, and a test asserting
	# the literal "3" goes red against a guard that is behaving correctly. That is
	# exactly what happened: this test passed on its author's branch and failed the
	# moment the branch was merged down.
	local expected
	expected="$(git -C "$root" rev-list --count "${MARKER_GIT_REF}..HEAD")"
	run "$script" supercred-demo-runner
	[ "$status" -eq 1 ]
	[[ "$output" == *"${expected} commits behind HEAD"* ]]
	# The distance must be real, not a placeholder the guard prints regardless.
	[ "$expected" -ge 3 ]
}

@test "image with no build marker is drift, not a pass" {
	# An image built before this guard existed. Every image built from the current
	# tree bakes a marker in, so its absence is a fact about the image, not a
	# failure to look.
	export MARKER_ABSENT=1
	run "$script" supercred-demo-runner
	[ "$status" -eq 1 ]
	[[ "$output" == *"carries no build marker"* ]]
}

@test "workload that is not deployed at all is drift" {
	export DEPLOYMENT_STATUS=1
	run "$script" supercred-demo-runner
	[ "$status" -eq 1 ]
	[[ "$output" == *"NOT DEPLOYED"* ]]
	[[ "$output" != *"every checked workload is running the current working tree"* ]]
}

# ─── Cannot verify: the requirement most likely to be got wrong ─────────────

@test "unreachable cluster is CANNOT VERIFY (exit 2), never OK" {
	export CLUSTER_STATUS=1
	run "$script" supercred-demo-runner
	[ "$status" -eq 2 ]
	[[ "$output" == *"CANNOT VERIFY"* ]]
	[[ "$output" == *"no reachable cluster"* ]]
	# The whole point: an absence of evidence must not read as evidence of health.
	[[ "$output" != *"fresh"* ]]
	[[ "$output" != *"every checked workload is running the current working tree"* ]]
}

@test "missing kubectl binary is CANNOT VERIFY (exit 2), never OK" {
	export KUBECTL_BIN="$BATS_TEST_TMPDIR/bin/definitely-not-installed"
	run "$script" supercred-demo-runner
	[ "$status" -eq 2 ]
	[[ "$output" == *"CANNOT VERIFY"* ]]
	[[ "$output" != *"fresh"* ]]
}

@test "failed readback is CANNOT VERIFY, distinct from a missing marker" {
	export EXEC_STATUS=1
	run "$script" supercred-demo-runner
	[ "$status" -eq 2 ]
	[[ "$output" == *"exec failed"* ]]
	[[ "$output" == *"unproven, not disproven"* ]]
	# Must NOT be reported as the marker-absent finding, which is a different bug
	# with a different fix.
	[[ "$output" != *"carries no build marker"* ]]
}

@test "deployment with no Running pod is CANNOT VERIFY, not fresh" {
	export POD_NAME=""
	run "$script" supercred-demo-runner
	[ "$status" -eq 2 ]
	[[ "$output" == *"no Running pod"* ]]
	[[ "$output" != *"fresh"* ]]
}

@test "unparseable marker is CANNOT VERIFY, not a silent pass" {
	export MARKER_GARBAGE=1
	run "$script" supercred-demo-runner
	[ "$status" -eq 2 ]
	[[ "$output" == *"unparseable"* ]]
	[[ "$output" != *"fresh"* ]]
}

# ─── Precedence and vacuity ────────────────────────────────────────────────

@test "no outcome other than a real match ever exits 0" {
	# The vacuity sweep. Every knob that represents "something is wrong or
	# unknown" must produce a non-zero exit. If any of these ever returns 0 the
	# guard has regressed into the failure mode it was written to remove.
	local knob rc
	for knob in "CLUSTER_STATUS=1" "DEPLOYMENT_STATUS=1" "EXEC_STATUS=1" \
		"MARKER_ABSENT=1" "MARKER_GARBAGE=1" "POD_NAME=" \
		"MARKER_SOURCE_ID=deadbeef"; do
		rc=0
		# shellcheck disable=SC2163
		(
			export "$knob"
			"$script" supercred-demo-runner >/dev/null 2>&1
		) || rc=$?
		if [ "$rc" -eq 0 ]; then
			echo "guard exited 0 with $knob set — vacuous pass" >&2
			return 1
		fi
	done
}

@test "proven drift outranks unverifiable when both are present" {
	# dashboard-signalloom has no fake deployment here (DEPLOYMENT_STATUS applies
	# to both), so run the pair with the runner stale: the actionable finding must
	# win the exit code while the other is still reported.
	export MARKER_SOURCE_ID="0000000000000000000000000000000000000000000000000000000000000bad"
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"DRIFT"* ]]
}

# ─── The fingerprint itself ────────────────────────────────────────────────

@test "fingerprint moves when a file the image COPYs changes" {
	# Without this property the whole guard is decorative.
	local before after probe
	probe="$root/d2-signalloom/apps/fe-signalloom/src/requirements.txt"
	before="$(source_id_for supercred-demo-runner)"
	cp "$probe" "$BATS_TEST_TMPDIR/probe.bak"
	echo "# staleness probe" >>"$probe"
	after="$(source_id_for supercred-demo-runner)"
	cp "$BATS_TEST_TMPDIR/probe.bak" "$probe"
	[ -n "$before" ]
	[ "$before" != "$after" ]
	[ "$before" = "$(source_id_for supercred-demo-runner)" ]
}

# ─── The workload registry, and the copies of it that must not exist ───────
#
# The guard was never wrong about what it checked. It was wrong about what it
# was ASKED to check: callers kept their own hardcoded workload lists, and
# scripts/acceptance-test.sh's list omitted fe-signalloom, so a 25-hour-stale
# portal served a 404 through a green suite. These tests pin the derivation so
# the copies cannot come back.

@test "--list emits the topology, and needs no cluster to do it" {
	# The whole point of deriving is that callers can enumerate workloads before
	# they know whether a cluster exists — otherwise a no-cluster run cannot tell
	# "skipped, nothing deployed" from "checked nothing".
	KUBECTL_BIN=/nonexistent/kubectl run "$script" --list
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	# workload<TAB>namespace on every line, no blanks.
	local line
	while IFS= read -r line; do
		[[ "$line" == *$'\t'* ]] || {
			echo "not tab-separated: [$line]" >&2
			return 1
		}
		[ -n "${line%%$'\t'*}" ]
		[ -n "${line##*$'\t'}" ]
	done <<<"$output"

	# The workload whose absence caused the incident.
	printf '%s\n' "$output" | grep -q '^fe-signalloom	' || {
		echo "fe-signalloom is not in the topology" >&2
		return 1
	}
}

@test "the two workload registries cannot disagree" {
	# WORKLOAD_TOPOLOGY locates a workload; source_id_workloads() decides which
	# are checked by default. A name in one and not the other is silently inert:
	# in topology only, it is never checked; in source_id only, it reports "not a
	# workload this guard knows how to locate" forever. Neither reads as a bug.
	local from_topology from_sourceid
	from_topology="$("$script" --list | cut -f1 | sort)"
	from_sourceid="$(source_id_workloads | sort)"
	[ "$from_topology" = "$from_sourceid" ] || {
		echo "registries disagree." >&2
		echo "WORKLOAD_TOPOLOGY:   $(echo "$from_topology" | tr '\n' ' ')" >&2
		echo "source_id_workloads: $(echo "$from_sourceid" | tr '\n' ' ')" >&2
		return 1
	}
}

@test "acceptance-test.sh derives its workload list instead of hardcoding one" {
	# The specific regression: `for _workload in supercred-demo-runner
	# dashboard-signalloom; do`. Asserting the POSITIVE (it consults --list) as
	# well as the absence, because a grep for the old literal alone would pass
	# against a file that had dropped the check altogether.
	local acceptance="$root/scripts/acceptance-test.sh"
	grep -q 'check-deployed-staleness.sh" --list' "$acceptance" || {
		echo "acceptance-test.sh does not derive its workload list from --list" >&2
		return 1
	}

	# No `for _workload in <literal names>`. Written as a separate `run` so the
	# assertion is the test's own line and cannot be neutered by errexit — a bare
	# `! grep …` mid-test is a no-op in bats, which this repo has been bitten by.
	run grep -nE 'for +_workload +in +[a-z]' "$acceptance"
	[ "$status" -ne 0 ] || {
		echo "acceptance-test.sh hardcodes a workload list again:" >&2
		echo "$output" >&2
		return 1
	}

	# And no hardcoded namespace on the staleness check — it was `-n
	# fe-signalloom`, correct only by coincidence.
	run grep -nE 'kubectl -n fe-signalloom get deployment' "$acceptance"
	[ "$status" -ne 0 ] || {
		echo "acceptance-test.sh hardcodes the staleness-check namespace:" >&2
		echo "$output" >&2
		return 1
	}
}

@test "every workload --list names is one the guard can actually check" {
	# A topology entry for a workload source-id cannot fingerprint is a guard
	# that reports CANNOT VERIFY forever, which trains people to ignore exit 2.
	local workload
	while IFS=$'\t' read -r workload _; do
		[ -n "$workload" ] || continue
		source_id_for "$workload" >/dev/null 2>&1 || {
			echo "topology names $workload, but source_id_for cannot fingerprint it" >&2
			return 1
		}
	done < <("$script" --list)
}

@test "runner path set is derived from the Dockerfile, not hand-maintained" {
	# A hand-written list develops blind spots the moment someone adds a COPY.
	# Every COPY source in the Dockerfile must appear in the fingerprinted set.
	local df missing=0 src
	df="$root/d2-signalloom/apps/supercred-demo-runner/Dockerfile"
	while read -r src; do
		source_id_copied_paths "$df" "x" | grep -qxF "$src" || {
			echo "COPY source not fingerprinted: $src" >&2
			missing=1
		}
	done < <(awk '/^[[:space:]]*COPY[[:space:]]/ && $0 !~ /--from=/ {
			for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i
		}' "$df")
	[ "$missing" -eq 0 ]
}

@test "the fingerprint ignores untracked build artefacts, so it survives a test run" {
	# The runner COPYs the whole of fe-signalloom/src, so running pytest once
	# leaves .coverage and a tree of .pyc files inside a hashed path. Before the
	# excludes, that changed the fingerprint every time anyone ran the suite, and
	# two checkouts of the same commit disagreed (dda1d702 vs 95b668d2, differing
	# in nothing else). A guard that reports drift against a matching deployment
	# is a guard that gets ignored.
	local src="$root/d2-signalloom/apps/fe-signalloom/src"
	local probe="$src/__pycache__/zz_guard_probe.cpython-312.pyc"
	local before after
	before="$(source_id_for supercred-demo-runner)"

	mkdir -p "$src/__pycache__"
	printf 'not real bytecode' >"$probe"
	after="$(source_id_for supercred-demo-runner)"
	rm -f "$probe"
	rmdir "$src/__pycache__" 2>/dev/null || true

	[ -n "$before" ]
	[ "$before" = "$after" ]

	# And the converse, so this cannot pass by the fingerprint being constant:
	# a real source file the image COPYs must still move it.
	local real="$src/zz_guard_probe_real.py"
	printf '# a file the Dockerfile COPYs\n' >"$real"
	local changed
	changed="$(source_id_for supercred-demo-runner)"
	rm -f "$real"
	[ "$before" != "$changed" ]
}
