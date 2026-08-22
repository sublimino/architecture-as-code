#!/usr/bin/env bash
#
# Four lanes, N times: destroy -> up -> estate -> tests -> doctor, all parallel.
#
# ─── Why a script and not a shell loop typed by hand ────────────────────────
#
# Three cycles x four lanes x five phases is sixty state transitions. Driving
# that by hand is how a run gets reported as "green" because nobody noticed one
# lane exited 2 in phase three. Every phase here records an explicit exit code
# per lane into a per-cycle results file, and the summary is DERIVED from those
# files rather than from what the operator remembers seeing.
#
# ─── The traps this encodes, each of which has already cost hours ───────────
#
#   * `yes` emits "y"; terraform destroy requires exactly "yes" and answers
#     "Destroy cancelled" to anything else. Hence `yes yes |`.
#   * A pipe masks the exit status of everything but the last command — and with
#     `set -o pipefail` it does something worse than mask it: `yes` dies of
#     SIGPIPE the moment terraform stops reading, so the pipeline reports 141
#     even when the destroy succeeded. Measured: `yes yes | make` where make
#     exits 0 returns 141 under pipefail. Hence ${PIPESTATUS[1]} — the index of
#     `make` in that pipeline, NOT [0], which is `yes` and is exactly the 141.
#   * ssh-agent refuses gcloud's operations and it misreports as a VM fault.
#     Hence SSH_AUTH_SOCK is unset once, at the top.
#   * A fresh worktree has none of the gitignored operational state, and the
#     absence surfaces as a terraform-outputs error naming the wrong subsystem.
#     Hence the preflight below refuses rather than letting the apply run — by
#     DELEGATING to worktree-bootstrap.sh, which owns that invariant.
#   * Teardown MUST fully complete before any create: four lanes at the 8-vCPU
#     floor need exactly 32 of a 32 CPU quota, so an overlap deadlocks. Capacity
#     is therefore a gate, not a warning: a cycle that cannot confirm the estate
#     is empty does not create.
#
# Usage: four-lane-loop.sh [cycles] [lanes...]
set -o pipefail

CYCLES="${1:-3}"; shift || true
LANES=("${@:-demo-1 demo-2 ci-1 ci-2}")
[ "${#LANES[@]}" -eq 1 ] && read -r -a LANES <<<"${LANES[0]}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${FOUR_LANE_OUT:-/tmp/four-lane}"
mkdir -p "$OUT"

unset SSH_AUTH_SOCK
export TF_STATE_BUCKET="${TF_STATE_BUCKET:-sl-port-over-sandbox-osramp-tfstate}"
export GCP_TF_VAR_FILE="${GCP_TF_VAR_FILE:-../../deploy/gcp/sl-port-over-sandbox.tfvars}"
export KUBESEC_AFM_ROOT="${KUBESEC_AFM_ROOT:-/home/andy/src/cp/kubesec-afm}"
export GOFLAGS="${GOFLAGS:--buildvcs=false}"
PROJECT="${GCP_PROJECT:-sl-port-over-sandbox}"

# The capacity poll's shape, injectable so the guard is testable without a
# ten-minute wall clock. Defaults are the operational values.
CAPACITY_TRIES="${CAPACITY_TRIES:-40}"
CAPACITY_SLEEP="${CAPACITY_SLEEP:-15}"

# The preflight is delegated, so the path to the delegate is a real dependency.
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$REPO_ROOT/scripts/gcp-tf/worktree-bootstrap.sh}"

log() { printf '%s | %s\n' "$(date '+%H:%M:%S')" "$*"; }

# ── PREFLIGHT ───────────────────────────────────────────────────────────────
#
# Refuse rather than discover a missing file after a full apply cycle.
#
# This function used to check the files itself. It no longer does, and the
# deletion is the point: scripts/gcp-tf/worktree-bootstrap.sh already owns
# "which gitignored operational state must be present, and what breaks without
# each piece", with 37 tests and a mutation proof behind it. Two implementations
# of one invariant drift, and the copy nobody is looking at is the one that
# stops matching reality — this copy had already diverged, checking
# `.keys/cosign.key` where the manifest checks `.keys`.
#
# What is genuinely local to this harness is not the CHECKING, it is the
# REQUIRED-SET. The manifest is deliberately conservative because it also gates
# `gcp-tf-up`, where a main checkout with no lane tfvars and no signing key is a
# supported state. This loop cannot run without either: it exports
# GCP_TF_VAR_FILE and it signs. That difference is a parameter, so it is passed
# as one.
#
# `check`, not `gate`: `gate` is a deliberate no-op outside a linked worktree,
# and this loop is normally driven FROM the main checkout — where deploy-sa is
# still mandatory and its absence still costs a full apply.
preflight() {
	if [ ! -x "$WORKTREE_SCRIPT" ]; then
		echo "MISSING: $WORKTREE_SCRIPT" >&2
		echo "" >&2
		echo "The worktree-state preflight cannot run. Refusing rather than skipping:" >&2
		echo "a guard whose absence is indistinguishable from its success is not a" >&2
		echo "guard, and the failure it prevents costs a full four-lane apply." >&2
		return 1
	fi

	# Repo-relative, and DERIVED from the exported value rather than written out
	# again — GCP_TF_VAR_FILE is relative to a terraform root, and a second
	# hardcoded spelling of the same filename is how the two stop agreeing.
	local var_file_rel="deploy/gcp/$(basename "$GCP_TF_VAR_FILE")"

	REPO_ROOT="$REPO_ROOT" REQUIRE_ALSO="$(printf '%s\n' \
		"${var_file_rel}|this loop passes it as GCP_TF_VAR_FILE; terraform applies with no lane definitions" \
		".keys/cosign.key|image signing refuses partway through the estate stage" \
		"${KUBESEC_AFM_ROOT}|the AFM stage aborts LATE, after building a multi-hundred-MB archive")" \
		"$WORKTREE_SCRIPT" check
}

# Run one make target across every lane in parallel; record per-lane exit codes.
fan_out() {
	local phase="$1" cycle="$2"; shift 2
	local rc_file="$OUT/c${cycle}-${phase}.rc"
	: >"$rc_file"
	local e
	for e in "${LANES[@]}"; do
		(
			"$@" "$e" >"$OUT/c${cycle}-${phase}-${e}.log" 2>&1
			echo "$e=$?" >>"$rc_file"
		) &
	done
	wait

	local recorded bad
	recorded="$(grep -c . "$rc_file" 2>/dev/null || true)"
	log "  ${phase}: $(tr '\n' ' ' <"$rc_file")"

	# A lane that recorded NOTHING is the dangerous case, and it is not the same
	# as a lane that recorded a failure. An empty results file must never read as
	# "nothing went wrong": the previous form computed
	# `grep -cv '=0$' file || echo 0`, which on an empty file yields the two-line
	# string "0\n0" because grep -c both PRINTS 0 and EXITS 1 — the `||` then
	# fires as well. `$(( "0\n0" > 0 ))` is a bash syntax error, so the guard
	# blew up rather than reporting. Measured, not assumed.
	if [ "${recorded:-0}" -ne "${#LANES[@]}" ]; then
		log "  ${phase}: REFUSING — ${recorded:-0} of ${#LANES[@]} lanes recorded an exit code"
		return 1
	fi

	bad="$(grep -cv '=0$' "$rc_file" 2>/dev/null || true)"
	[ "${bad:-0}" -gt 0 ] && return 1
	return 0
}

do_destroy() { ( cd "$REPO_ROOT" && yes yes | make gcp-tf-destroy ENV="$1" CONFIRM="$1"; exit "${PIPESTATUS[1]}" ); }
do_up()      { ( cd "$REPO_ROOT" && make gcp-tf-up ENV="$1" ); }
do_estate()  { ( cd "$REPO_ROOT" && GCP_TF_DEMO_ALLOW_DIRTY=1 make gcp-tf-demo-up ENV="$1" ); }
do_doctor()  { ( cd "$REPO_ROOT" && make doctor-node ENV="$1" ); }

# Capacity must be genuinely free before any create, or the applies deadlock
# against the 32-CPU cap. Verified, not assumed — and "verified" means the
# listing was actually obtained.
wait_for_capacity() {
	local tries=0 listing rc n
	while [ "$tries" -lt "$CAPACITY_TRIES" ]; do
		# The assignment and the status are separate statements on purpose.
		# `local listing="$(...)"` returns `local`'s status, not the command's,
		# so the failure would be invisible. And piping gcloud straight into
		# `wc -l` is worse still: an expired credential produces no output, wc
		# reports 0, and "capacity free (0 instances)" is announced on the
		# strength of an error — launching four applies into an estate that is
		# still standing, which is the deadlock this function exists to prevent.
		listing="$(gcloud compute instances list --project "$PROJECT" --format='value(name)' 2>/dev/null)"
		rc=$?
		if [ "$rc" -ne 0 ]; then
			log "  capacity UNKNOWN: gcloud instances list exited ${rc} — an error is not an empty estate"
		else
			n="$(printf '%s' "$listing" | grep -c . || true)"
			if [ "${n:-0}" -eq 0 ]; then
				log "  capacity free (0 instances)"
				return 0
			fi
			log "  capacity: ${n} instance(s) still present"
		fi
		sleep "$CAPACITY_SLEEP"; tries=$((tries + 1))
	done
	log "  capacity NOT confirmed free after ${CAPACITY_TRIES} checks"
	return 1
}

# The verdict is DERIVED from each lane's own summary.json, not from the driver's
# exit code: an ABORTED run and a run whose tests failed both exit non-zero and
# mean very different things.
record_verdicts() {
	local c="$1" e s v
	for e in "${LANES[@]}"; do
		s="$REPO_ROOT/demo-reports/$e/summary.json"
		if [ -r "$s" ]; then
			v="$(jq -r '"\(.outcome) phase=\(.phase) \(.passed)/\(.total_stages)"' "$s" 2>/dev/null)"
			# jq failing leaves this empty, and an empty verdict renders as a
			# line with nothing after the lane name — which reads as "fine".
			[ -n "$v" ] || v="UNREADABLE-VERDICT"
		else
			v="NO-VERDICT"
		fi
		echo "cycle=$c lane=$e $v" >>"$OUT/summary.txt"
	done
}

four_lane_main() {
	local c
	for c in $(seq 1 "$CYCLES"); do
		log "═══ CYCLE $c/$CYCLES ═══"
		preflight || exit 1

		fan_out destroy "$c" do_destroy || log "  (destroy reported failures — continuing; destroy only frees capacity)"

		# A gate, not a warning. The header states teardown must fully complete
		# before any create; warning and then creating anyway is that invariant
		# written down and not enforced.
		if ! wait_for_capacity; then
			log "  CYCLE $c ABORTED: capacity not confirmed free, refusing to create into it"
			echo "cycle=$c result=CAPACITY_NOT_FREE" >>"$OUT/summary.txt"
			continue
		fi

		if ! fan_out up "$c" do_up; then
			log "  CYCLE $c ABORTED: infrastructure did not come up"
			echo "cycle=$c result=INFRA_FAIL" >>"$OUT/summary.txt"
			continue
		fi

		fan_out estate "$c" do_estate || true
		fan_out doctor "$c" do_doctor || true

		record_verdicts "$c"
		log "  cycle $c recorded"
	done

	log "═══ ALL CYCLES COMPLETE ═══"
	cat "$OUT/summary.txt" 2>/dev/null
}

# Executed, not sourced. The suite drives preflight/fan_out/wait_for_capacity/
# record_verdicts directly against THIS file rather than against a copy of them
# extracted by sed — a copy is a second implementation, and a test of a second
# implementation proves nothing about the one that runs.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	four_lane_main
fi
