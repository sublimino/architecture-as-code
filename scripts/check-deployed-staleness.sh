#!/usr/bin/env bash
# check-deployed-staleness.sh — is the code that ANSWERS REQUESTS the code in the working tree?
#
#   check-deployed-staleness.sh                       # every instrumented workload
#   check-deployed-staleness.sh supercred-demo-runner # one workload
#
# Exit codes are the point of this script, so they are stated first:
#
#   0  VERIFIED FRESH   every checked workload was reached, its build identity
#                       was read out of the running container, and it matches
#                       the working tree. A positive proof, not an absence of
#                       evidence.
#   1  DRIFT            at least one workload is provably running something
#                       other than the working tree (or is not deployed at all).
#   2  CANNOT VERIFY    the question was not answered — no kubectl, no reachable
#                       cluster, no running pod, or the readback failed.
#
# ─── Why 2 exists, and why it is not 0 ──────────────────────────────────────
#
# A guard that reports OK when it could not reach the cluster is worse than no
# guard, because it manufactures confidence. That is the precise failure shape
# this script was written to remove, so it must not reintroduce it in its own
# implementation. "Cannot verify" is therefore a distinct, non-zero, loudly
# worded outcome that can never be mistaken for "verified matching" by a human
# skimming output or by a Makefile checking $?.
#
# ─── What went wrong, that this exists to catch ─────────────────────────────
#
# On 2026-08-13 a streaming fix landed across 22 commits and was verified by 315
# backend tests, 1657 dashboard tests and a browser harness. It was reported as
# working. It was not working: the pods answering the requests predated every
# commit.
#
#   supercred-demo-runner  age 3h56m  ->  demo_runner.py still had the old read
#   dashboard-signalloom   age 138m   ->  bundle contained none of the fix
#
# Every test was green. Every one of them tested the SOURCE TREE. Nothing tested
# what was RUNNING, and nothing anywhere said "the code you are reading is not
# the code answering your requests". The gap was not a missing assertion inside
# any one test — it was a missing category of assertion.
#
# This is the second instance of the class. The first: scripts/acceptance-test.sh
# does not rebuild, so a dashboard source fix stays invisible to a spec until
# somebody rebuilds and rolls. Same root cause, different surface — which is why
# this is a guard rather than a note in a runbook.
#
# ─── What is compared, and why ──────────────────────────────────────────────
#
# A content fingerprint of the files that go into each image, baked in at build
# time and read back OUT OF THE RUNNING CONTAINER'S FILESYSTEM.
#
# The full argument for that choice over image tags, git SHAs and image digests
# is in scripts/lib/source-id.sh, which owns the single definition of the
# fingerprint. The short version: tags are mutable and were byte-identical
# across the rebuild that caused the incident; a git SHA does not move on an
# uncommitted edit, which is most edits here; and the pod-reported imageID is a
# local config digest for the runner but a registry manifest digest for the
# dashboard, so it cannot be compared uniformly.
#
# Reading the marker out of the running container is deliberate. Anything read
# from a manifest, a tag, a registry or a build log describes what was INTENDED.
# Only the container's own filesystem describes what is THERE.
#
# ─── Why the readback cannot report "absent" as a success ───────────────────
#
# `kubectl exec … -- cat /etc/osramp-build-id` returns non-zero both when the
# file is missing and when the exec machinery itself failed, and those are
# completely different findings: the first proves the image predates this guard
# (drift), the second proves nothing (cannot verify). Collapsing them would let
# an unreachable API server read as a stale image, or worse, be shrugged off.
#
# So the readback runs `cat … || echo MARKER_ABSENT` inside the container: if
# exec works at all we get a definite answer, and only a genuine exec failure
# yields empty output. Both images ship a shell (python:3.12-slim, alpine), and
# the marker is plain key=value text so nothing but `cat` is required inside.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${SCRIPT_DIR}/lib/source-id.sh"

# Injectable so the BATS suite can drive the whole script against a fake client
# with no cluster, per this repo's local-fake convention (see
# test/kind-load-verified.bats, test/supervise-port-forward.bats). The failure
# paths are the ones worth testing, and a real cluster that happens to be
# healthy today exercises none of them.
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

# workload|namespace|container
#
# ─── Why fe-signalloom is here, and what is still not ───────────────────────
#
# It was NOT here until 2026-08-18, and its absence was the whole reason a
# 25-hour-stale portal image served a 404 to a live demo with every test green.
# The guard reported VERIFIED FRESH throughout, truthfully, about two other
# workloads. A guard that answers a narrower question than the one people read
# off it is the failure mode this script's own header warns about, reproduced
# one list-entry lower down.
#
# signal-ingest is deliberately NOT here, and cannot be. It is
# gcr.io/distroless/static-debian12 with no shell and no coreutils, so the
# `kubectl exec … -- sh -c cat` readback below has nothing to execute; adding it
# would yield CANNOT VERIFY on every run, which is noise that trains people to
# ignore exit 2. It was the SECOND stale image in that same incident, so the
# gap is real and is covered elsewhere: test/api-route-liveness.bats asks the
# question over HTTP, which needs nothing inside the container. If signal-ingest
# ever gains a shell, it belongs here too.
WORKLOAD_TOPOLOGY=(
	"supercred-demo-runner|fe-signalloom|runner"
	"dashboard-signalloom|fe-signalloom|dashboard"
	"fe-signalloom|fe-signalloom|discovery-portal"
)

log() { printf '\033[1;36m[deployed]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[deployed] ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[deployed] ✗\033[0m %s\n' "$*" >&2; }
unk() { printf '\033[1;33m[deployed] ?\033[0m %s\n' "$*" >&2; }

DRIFT=0
UNVERIFIED=0

topology_field() {
	local workload="$1" field="$2" entry w ns c
	for entry in "${WORKLOAD_TOPOLOGY[@]}"; do
		IFS='|' read -r w ns c <<<"$entry"
		[ "$w" = "$workload" ] || continue
		case "$field" in
		namespace) printf '%s' "$ns" ;;
		container) printf '%s' "$c" ;;
		esac
		return 0
	done
	return 1
}

# "3h56m" from an RFC3339 timestamp — the same unit a human reads off
# `kubectl get pods`, so a failure here can be cross-checked by eye immediately.
human_age() {
	local ts="$1" started now delta
	# `date -d ''` does not fail — it silently resolves to midnight today, which
	# would report a pod of unknown age as up to 23h old. An empty timestamp means
	# we did not learn the age, and must say so.
	if [ -z "$ts" ] || ! started="$(date -d "$ts" +%s 2>/dev/null)"; then
		printf 'unknown'
		return 0
	fi
	now="$(date +%s)"
	delta=$((now - started))
	# An `[ … ] && delta=0` one-liner here returns non-zero whenever the age is
	# POSITIVE, which under `set -e` aborts this function inside its command
	# substitution and yields an empty age on every real run. Written as an `if`
	# so the normal path cannot fail.
	if [ "$delta" -lt 0 ]; then
		delta=0
	fi
	printf '%dh%dm' $((delta / 3600)) $(((delta % 3600) / 60))
}

# "22 commits" when the baked ref is a commit this checkout knows about.
# Silent when it is not — a dirty or unknown ref is common and is already
# reported verbatim; guessing a distance from it would be fabrication.
commit_distance() {
	local baked="$1"
	case "$baked" in
	'' | unknown | *-dirty) return 0 ;;
	esac
	git -C "${SOURCE_ID_REPO_ROOT}" cat-file -e "${baked}^{commit}" 2>/dev/null || return 0
	local n
	n="$(git -C "${SOURCE_ID_REPO_ROOT}" rev-list --count "${baked}..HEAD" 2>/dev/null)" || return 0
	if [ -n "$n" ] && [ "$n" != "0" ]; then
		printf ', %s commits behind HEAD' "$n"
	fi
	# Always succeeds: this is a decoration on an error message, and under
	# `set -e` a non-zero return from a decoration must never alter control flow.
	return 0
}

marker_value() {
	local blob="$1" key="$2"
	printf '%s\n' "$blob" | awk -F= -v k="$key" '$1 == k { print $2; exit }'
}

check_workload() {
	local workload="$1"
	local ns container expected pod created age raw running_id baked_ref

	ns="$(topology_field "$workload" namespace)" || {
		unk "$workload: not a workload this guard knows how to locate"
		UNVERIFIED=1
		return
	}
	container="$(topology_field "$workload" container)"

	if ! expected="$(source_id_for "$workload")"; then
		unk "$workload: could not fingerprint the working tree (see above)"
		UNVERIFIED=1
		return
	fi

	if ! "$KUBECTL_BIN" -n "$ns" get deployment "$workload" >/dev/null 2>&1; then
		bad "$workload: NOT DEPLOYED — no Deployment in namespace $ns."
		printf '           Nothing is running this code, so nothing can be exercising it.\n' >&2
		DRIFT=1
		return
	fi

	# The newest Running pod. Newest because during a rollout an old and a new
	# ReplicaSet coexist, and answering with the OLD one would report drift on a
	# deployment that is in the middle of correctly fixing itself.
	#
	# `|| true`: with no Running pod the pipeline yields nothing, `read` hits EOF
	# and returns non-zero, and under `set -e` that would abort the script with a
	# bare exit 1 — silently converting "cannot verify" into "drift", the exact
	# conflation this guard exists to prevent.
	pod='' created=''
	read -r pod created < <("$KUBECTL_BIN" -n "$ns" get pods \
		-l "app.kubernetes.io/name=${workload}" \
		--field-selector=status.phase=Running \
		--sort-by=.metadata.creationTimestamp \
		-o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null \
		| tail -1) || true

	if [ -z "${pod:-}" ]; then
		unk "$workload: Deployment exists but no Running pod — cannot read what is deployed."
		printf '           This is UNVERIFIED, not OK: a rollout may be in progress or crash-looping.\n' >&2
		UNVERIFIED=1
		return
	fi

	age="$(human_age "${created:-}")"

	# See the header: `|| echo MARKER_ABSENT` is what separates "the image has no
	# marker" (a finding) from "exec did not work" (not a finding).
	if ! raw="$("$KUBECTL_BIN" -n "$ns" exec "$pod" -c "$container" -- \
		sh -c "cat ${SOURCE_ID_MARKER_PATH} 2>/dev/null || echo MARKER_ABSENT" 2>/dev/null)" ||
		[ -z "$raw" ]; then
		unk "$workload: could not read the build marker from pod $pod (exec failed)."
		printf '           This is UNVERIFIED, not OK — the deployed state is unproven, not disproven.\n' >&2
		UNVERIFIED=1
		return
	fi

	if [ "$raw" = "MARKER_ABSENT" ]; then
		bad "$workload: STALE — pod $pod (age $age) carries no build marker at all."
		printf '           Every image built from the current tree bakes one in, so this image\n' >&2
		printf '           was built before the marker existed. Rebuild and roll it.\n' >&2
		DRIFT=1
		return
	fi

	running_id="$(marker_value "$raw" source_id)"
	baked_ref="$(marker_value "$raw" git_ref)"

	if [ -z "$running_id" ]; then
		unk "$workload: build marker in pod $pod is unparseable — no source_id line."
		UNVERIFIED=1
		return
	fi

	if [ "$running_id" = "$expected" ]; then
		ok "$workload: fresh — pod $pod (age $age) runs the working tree (${expected:0:12})."
		return
	fi

	bad "$workload: STALE — pod $pod has been running ${age}$(commit_distance "$baked_ref")."
	printf '           running from source  %s  (built at git %s)\n' "${running_id:0:12}" "${baked_ref:-unknown}" >&2
	printf '           working tree is      %s  (git %s)\n' "${expected:0:12}" "$(source_id_git_ref)" >&2
	printf '           Tests that read the source tree will pass and prove nothing about\n' >&2
	printf '           this pod. Rebuild the image and roll the Deployment.\n' >&2
	DRIFT=1
}

main() {
	local requested=("$@")
	if [ "${#requested[@]}" -eq 0 ]; then
		mapfile -t requested < <(source_id_workloads)
	fi

	# Preflight is separate from the per-workload loop on purpose. If the cluster
	# is unreachable, every workload would otherwise fail individually with a
	# readback error and bury the one fact that matters.
	if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
		printf '\n'
		unk "CANNOT VERIFY: $KUBECTL_BIN is not on PATH."
		printf '           No claim is being made about the deployed workloads.\n\n' >&2
		exit 2
	fi
	if ! "$KUBECTL_BIN" cluster-info >/dev/null 2>&1; then
		printf '\n'
		unk "CANNOT VERIFY: no reachable cluster."
		printf '           The deployed state is unproven, NOT proven matching. Nothing below ran.\n\n' >&2
		exit 2
	fi

	printf '\n── is the running code the code in the working tree? ──\n\n'
	local workload
	for workload in "${requested[@]}"; do
		check_workload "$workload"
	done
	printf '\n'

	# Precedence: a proven fault outranks an unproven one, because it is the
	# actionable finding. Both are reported above regardless, and both are
	# non-zero, so neither can be read as a pass.
	if [ "$DRIFT" -ne 0 ]; then
		bad 'DRIFT: the deployed code is not the code in the working tree.'
		[ "$UNVERIFIED" -ne 0 ] && unk 'and at least one other workload could not be verified at all.'
		printf '\n' >&2
		exit 1
	fi
	if [ "$UNVERIFIED" -ne 0 ]; then
		unk 'CANNOT VERIFY: at least one workload was not proven to match.'
		printf '           Treat this as untested, not as passing.\n\n' >&2
		exit 2
	fi
	# Name what was checked. "All clear" phrasing over a two-workload scope reads
	# as an estate-wide guarantee, and an overclaimed pass is a quieter version of
	# the same failure this guard exists to remove: fe-signalloom, fleet-manager,
	# cardvault, policy-engine and the AFM backend are all built from this repo,
	# carry no build marker yet, and are NOT covered below.
	ok "every checked workload is running the current working tree: ${requested[*]}"
	printf '           (only instrumented workloads are checked; others are not covered.)\n\n'
}

main "$@"
