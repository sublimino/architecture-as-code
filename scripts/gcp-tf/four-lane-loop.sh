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
#   * A pipe masks the exit status of everything but the last command, so a
#     failing make behind `| tail` reports 0. Hence ${PIPESTATUS[0]}.
#   * ssh-agent refuses gcloud's operations and it misreports as a VM fault.
#     Hence SSH_AUTH_SOCK is unset once, at the top.
#   * A fresh worktree has none of the gitignored operational state, and the
#     absence surfaces as a terraform-outputs error naming the wrong subsystem.
#     Hence the preflight below refuses rather than letting the apply run.
#   * Teardown MUST fully complete before any create: four lanes at the 8-vCPU
#     floor need exactly 32 of a 32 CPU quota, so an overlap deadlocks.
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

log() { printf '%s | %s\n' "$(date '+%H:%M:%S')" "$*"; }

# ── PREFLIGHT ───────────────────────────────────────────────────────────────
# Refuse rather than discover a missing file after a full apply cycle. Every
# one of these is gitignored and therefore absent from a fresh worktree.
preflight() {
	local missing=0 f
	for f in deploy/gcp/sl-port-over-sandbox.tfvars deploy/gcp/deploy-sa; do
		[ -e "$REPO_ROOT/$f" ] || { echo "MISSING: $f" >&2; missing=1; }
	done
	[ -e "$REPO_ROOT/.keys/cosign.key" ] || { echo "MISSING: .keys/cosign.key" >&2; missing=1; }
	[ -d "$KUBESEC_AFM_ROOT" ] || { echo "MISSING: KUBESEC_AFM_ROOT=$KUBESEC_AFM_ROOT" >&2; missing=1; }
	if [ "$missing" -ne 0 ]; then
		echo "" >&2
		echo "This worktree is missing untracked operational state. Copy it from the" >&2
		echo "main checkout before running; a missing deploy-sa in particular does NOT" >&2
		echo "fail fast — terraform applies successfully and then the hand-off errors" >&2
		echo "with a message blaming terraform/environments/outputs.tf." >&2
		return 1
	fi
	return 0
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
	# `grep -c` PRINTS the count on stdout and separately EXITS 1 when that count
	# is zero. So `$(grep -c ... || echo 0)` appends a second line and yields
	# "0\n0", which then explodes in the arithmetic below with
	# `syntax error in expression (error token is "0")`. The || looks like
	# defensive shell and is the entire defect — it fires exactly in the SUCCESS
	# case, so the harness died only when every lane passed.
	local bad
	bad="$(grep -cv '=0$' "$rc_file" 2>/dev/null)" || true
	bad="${bad//[^0-9]/}"
	bad="${bad:-0}"
	log "  ${phase}: $(tr '\n' ' ' <"$rc_file")"
	[ "$bad" -gt 0 ] && return 1
	return 0
}

do_destroy() { ( cd "$REPO_ROOT" && yes yes | make gcp-tf-destroy ENV="$1" CONFIRM="$1"; exit "${PIPESTATUS[1]}" ); }
do_up()      { ( cd "$REPO_ROOT" && make gcp-tf-up ENV="$1" ); }
do_estate()  { ( cd "$REPO_ROOT" && GCP_TF_DEMO_ALLOW_DIRTY=1 make gcp-tf-demo-up ENV="$1" ); }
do_doctor()  { ( cd "$REPO_ROOT" && make doctor-node ENV="$1" ); }

# Capacity must be genuinely free before any create, or the applies deadlock
# against the 32-CPU cap. Verified, not assumed.
wait_for_capacity() {
	local tries=0
	while [ "$tries" -lt 40 ]; do
		local n
		n="$(gcloud compute instances list --project "$PROJECT" --format='value(name)' 2>/dev/null | wc -l)"
		[ "$n" -eq 0 ] && { log "  capacity free (0 instances)"; return 0; }
		sleep 15; tries=$((tries + 1))
	done
	log "  WARNING: instances still present after teardown wait"
	return 1
}

for c in $(seq 1 "$CYCLES"); do
	log "═══ CYCLE $c/$CYCLES ═══"
	preflight || exit 1

	fan_out destroy "$c" do_destroy || log "  (destroy reported failures — continuing; destroy only frees capacity)"
	wait_for_capacity

	if ! fan_out up "$c" do_up; then
		log "  CYCLE $c ABORTED: infrastructure did not come up"
		echo "cycle=$c result=INFRA_FAIL" >>"$OUT/summary.txt"
		continue
	fi

	fan_out estate "$c" do_estate || true
	fan_out doctor "$c" do_doctor || true

	# The verdict is DERIVED from each lane's own summary.json, not from the
	# driver's exit code: an ABORTED run and a run whose tests failed both exit
	# non-zero and mean very different things.
	for e in "${LANES[@]}"; do
		s="$REPO_ROOT/demo-reports/$e/summary.json"
		if [ -r "$s" ]; then
			v="$(jq -r '"\(.outcome) phase=\(.phase) \(.passed)/\(.total_stages)"' "$s" 2>/dev/null)"
		else
			v="NO-VERDICT"
		fi
		echo "cycle=$c lane=$e $v" >>"$OUT/summary.txt"
	done
	log "  cycle $c recorded"
done

log "═══ ALL CYCLES COMPLETE ═══"
cat "$OUT/summary.txt" 2>/dev/null
