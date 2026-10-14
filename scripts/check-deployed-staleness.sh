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

if [ -z "${KUBECONFIG:-}" ]; then
	if [ -f /tmp/osramp-kubeconfig.yaml ]; then
		export KUBECONFIG="/tmp/osramp-kubeconfig.yaml"
	elif [ -f /tmp/osramp.kubeconfig ]; then
		export KUBECONFIG="/tmp/osramp.kubeconfig"
	fi
fi

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
# ─── Distroless and standard workload coverage ─────────────────────────────
#
# Workloads with shells (supercred-demo-runner, dashboard, docs, fe-signalloom)
# are checked via in-container /etc/osramp-build-id readback.
# Distroless workloads with no shell (like signal-ingest, gcr.io/distroless/static-debian12)
# are verified by matching their deployed container image tag against the
# working tree's source-id / image-tag (e.g. src-<16 hex> from imagetag/signal-ingest-image-tag.sh).
#
# Dynamic discovery walks Flux kustomization configuration (apps/fe-signalloom/local)
# to detect all declared workloads (Deployments, StatefulSets, DaemonSets) so new
# workloads added to Flux are automatically tracked.
WORKLOAD_TOPOLOGY=(
	"supercred-demo-runner|fe-signalloom|runner"
	"dashboard-signalloom|fe-signalloom|dashboard"
	"docs-signalloom|fe-signalloom|docs"
	"fe-signalloom|fe-signalloom|discovery-portal"
	"signal-ingest|fe-signalloom|signal-ingest"
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

# Dynamic discovery of workloads declared in Flux kustomizations.
discover_flux_workloads() {
	local kdir="${1:-${SOURCE_ID_REPO_ROOT}/d2-signalloom/apps/fe-signalloom/local}"
	[ -d "$kdir" ] || return 0

	local raw_yaml=""
	if [ -n "${KUBECTL_BIN:-}" ] && command -v "$KUBECTL_BIN" >/dev/null 2>&1 && [ "$KUBECTL_BIN" != "/nonexistent/kubectl" ]; then
		raw_yaml="$("$KUBECTL_BIN" kustomize "$kdir" 2>/dev/null || true)"
	fi
	if [ -z "$raw_yaml" ] && command -v kubectl >/dev/null 2>&1; then
		raw_yaml="$(kubectl kustomize "$kdir" 2>/dev/null || true)"
	fi
	if [ -z "$raw_yaml" ] && command -v kustomize >/dev/null 2>&1; then
		raw_yaml="$(kustomize build "$kdir" 2>/dev/null || true)"
	fi

	if [ -n "$raw_yaml" ] && command -v yq >/dev/null 2>&1; then
		printf '%s\n' "$raw_yaml" | yq -r '
			select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet") |
			. as $item |
			($item.spec.template.spec.containers[0].name // $item.metadata.name) as $cname |
			[$item.metadata.name, ($item.metadata.namespace // "fe-signalloom"), $cname] |
			@tsv
		' 2>/dev/null | tr '\t' '|' || true
		return 0
	fi

	walk_kustomize_workloads "$kdir"
}

walk_kustomize_workloads() {
	local dir="$1"
	local kfile="$dir/kustomization.yaml"
	[ -f "$kfile" ] || return 0

	local in_res=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^resources: ]]; then
			in_res=1
			continue
		fi
		if [ "$in_res" -eq 1 ]; then
			if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
				local res="${BASH_REMATCH[1]}"
				res="${res%%#*}"
				res="$(echo "$res" | tr -d " \t\r\n")"
				[ -z "$res" ] && continue
				local target="$dir/$res"
				if [ -d "$target" ]; then
					walk_kustomize_workloads "$target"
				elif [ -f "$target" ]; then
					parse_workload_file "$target"
				fi
			elif [[ "$line" =~ ^[a-zA-Z] ]]; then
				in_res=0
			fi
		fi
	done < "$kfile"
}

parse_workload_file() {
	local f="$1"
	[ -f "$f" ] || return 0
	if grep -qE '^kind:[[:space:]]+(Deployment|StatefulSet|DaemonSet)' "$f"; then
		local name ns container
		name="$(awk '/^metadata:/ {m=1} m && /^[[:space:]]+name:[[:space:]]+/ {print $2; exit}' "$f")"
		ns="$(awk '/^metadata:/ {m=1} m && /^[[:space:]]+namespace:[[:space:]]+/ {print $2; exit}' "$f")"
		container="$(awk '/^[[:space:]]+containers:/ {c=1} c && /^[[:space:]]*- name:[[:space:]]+/ {print $3; exit}' "$f")"
		[ -n "$name" ] || return 0
		[ -n "$ns" ] || ns="fe-signalloom"
		[ -n "$container" ] || container="$name"
		printf '%s|%s|%s\n' "$name" "$ns" "$container"
	fi
}

load_flux_workloads() {
	local entry w ns c
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		IFS='|' read -r w ns c <<<"$entry"
		if ! topology_field "$w" namespace >/dev/null 2>&1; then
			WORKLOAD_TOPOLOGY+=("$entry")
		fi
	done < <(discover_flux_workloads "$@")
}

is_distroless() {
	local workload="$1"
	case "$workload" in
	signal-ingest|fleet-manager|policy-engine) return 0 ;;
	esac
	local df
	df="$(source_id_dockerfile "$workload" 2>/dev/null || true)"
	if [ -n "$df" ] && [ -f "${SOURCE_ID_REPO_ROOT}/${df}" ]; then
		if grep -qE '^FROM[[:space:]]+(gcr\.io/distroless|scratch)' "${SOURCE_ID_REPO_ROOT}/${df}"; then
			return 0
		fi
	fi
	return 1
}

check_distroless_workload() {
	local workload="$1" ns="$2" container="$3" pod="$4" age="$5"
	local running_img="" running_tag="" expected_tag=""

	# 1. Determine running image from pod status or deployment
	running_img="$("$KUBECTL_BIN" -n "$ns" get pod "$pod" \
		-o "jsonpath={.status.containerStatuses[?(@.name=='$container')].image}" 2>/dev/null || true)"
	if [ -z "$running_img" ]; then
		running_img="$("$KUBECTL_BIN" -n "$ns" get pod "$pod" \
			-o "jsonpath={.status.containerStatuses[0].image}" 2>/dev/null || true)"
	fi
	if [ -z "$running_img" ]; then
		running_img="$("$KUBECTL_BIN" -n "$ns" get deployment "$workload" \
			-o "jsonpath={.spec.template.spec.containers[?(@.name=='$container')].image}" 2>/dev/null || true)"
	fi
	if [ -z "$running_img" ]; then
		running_img="$("$KUBECTL_BIN" -n "$ns" get deployment "$workload" \
			-o "jsonpath={.spec.template.spec.containers[0].image}" 2>/dev/null || true)"
	fi

	if [ -z "$running_img" ]; then
		unk "$workload: CANNOT VERIFY — could not determine running image from pod $pod."
		printf '           This is UNVERIFIED, not OK: image inspection failed.\n' >&2
		UNVERIFIED=1
		return
	fi

	running_tag="${running_img##*:}"
	running_tag="${running_tag##*@}"

	# 2. Determine expected tag from working tree
	case "$workload" in
	signal-ingest)
		if [ -x "${SCRIPT_DIR}/signal-ingest-image-tag.sh" ]; then
			expected_tag="$("${SCRIPT_DIR}/signal-ingest-image-tag.sh" 2>/dev/null || true)"
		fi
		if [ -z "$expected_tag" ] && command -v go >/dev/null 2>&1; then
			expected_tag="$(cd "${SOURCE_ID_REPO_ROOT}/d2-signalloom/apps/signal-ingest" && \
				GOPATH="${GOPATH:-/tmp/gopath}" GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GONOSUMDB="*" \
				go run ./cmd/image-tag 2>/dev/null || true)"
		fi
		;;
	policy-engine)
		if [ -x "${SCRIPT_DIR}/policy-engine-image-tag.sh" ]; then
			expected_tag="$("${SCRIPT_DIR}/policy-engine-image-tag.sh" --no-dirty-check 2>/dev/null || true)"
		fi
		;;
	esac

	if [ -z "$expected_tag" ]; then
		expected_tag="$(source_id_for "$workload" 2>/dev/null || true)"
	fi

	if [ -z "$expected_tag" ]; then
		unk "$workload: CANNOT VERIFY — could not determine expected tag for working tree."
		printf '           This is UNVERIFIED, not OK: source fingerprinting failed.\n' >&2
		UNVERIFIED=1
		return
	fi

	local clean_running="${running_tag#src-}"
	local clean_expected="${expected_tag#src-}"
	if [ "$running_tag" = "$expected_tag" ] || \
	   [ "$clean_running" = "$clean_expected" ] || \
	   [[ "$clean_running" == "$clean_expected"* ]] || \
	   [[ "$clean_expected" == "$clean_running"* ]]; then
		ok "$workload: VERIFIED FRESH (tag $running_tag) — pod $pod (age $age) runs the working tree."
		return
	fi

	bad "$workload: DRIFT (running $running_tag, working tree expects $expected_tag)"
	printf '           pod %s (age %s) is running image with tag %s\n' "$pod" "$age" "$running_tag" >&2
	printf '           working tree expects tag %s\n' "$expected_tag" >&2
	printf '           Rebuild the image and roll the Deployment.\n' >&2
	DRIFT=1
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
	printf '%s\n' "$blob" | awk -F= -v k="$key" '!f && $1 == k { print $2; f = 1 }'
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
		local any_pod any_reason
		any_pod='' any_reason=''
		read -r any_pod any_reason < <("$KUBECTL_BIN" -n "$ns" get pods \
			-l "app.kubernetes.io/name=${workload}" \
			--sort-by=.metadata.creationTimestamp \
			-o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
			| tail -1) || true
		if [ -n "$any_reason" ]; then
			unk "$workload: CANNOT VERIFY — pod ${any_pod:-unknown} is in $any_reason."
			printf '           This is UNVERIFIED, not OK: a rollout is failing or stuck in %s.\n' "$any_reason" >&2
		else
			unk "$workload: Deployment exists but no Running pod — cannot read what is deployed."
			printf '           This is UNVERIFIED, not OK: a rollout may be in progress or crash-looping.\n' >&2
		fi
		UNVERIFIED=1
		return
	fi

	local waiting_reason
	waiting_reason="$("$KUBECTL_BIN" -n "$ns" get pod "$pod" \
		-o "jsonpath={.status.containerStatuses[?(@.name=='$container')].state.waiting.reason}" 2>/dev/null || true)"
	if [ -z "$waiting_reason" ]; then
		waiting_reason="$("$KUBECTL_BIN" -n "$ns" get pod "$pod" \
			-o "jsonpath={.status.containerStatuses[*].state.waiting.reason}" 2>/dev/null || true)"
	fi
	if [ -n "$waiting_reason" ]; then
		unk "$workload: CANNOT VERIFY — pod $pod container is in $waiting_reason."
		printf '           This is UNVERIFIED, not OK: container is not healthy.\n' >&2
		UNVERIFIED=1
		return
	fi

	age="$(human_age "${created:-}")"

	if is_distroless "$workload"; then
		check_distroless_workload "$workload" "$ns" "$container" "$pod" "$age"
		return
	fi

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
	# `--list` prints the instrumented workloads and where they live, one
	# `workload<TAB>namespace` per line, and exits 0.
	#
	# It exists so that CALLERS do not have to keep their own copy of this list.
	# scripts/acceptance-test.sh did keep one — hardcoded to two workloads — and
	# so never staleness-checked fe-signalloom at all, which is the whole reason
	# a 25-hour-stale portal served a 404 through a green suite. Adding one entry
	# to that copy would have fixed the instance and left the mechanism intact
	# for the next workload; deriving it removes the mechanism.
	#
	# Deliberately before the kubectl preflight below: this answers a question
	# about the REPO, not the cluster, so it must work with no cluster, no
	# kubectl, and in CI lint stages. Routing it through the preflight would make
	# callers unable to enumerate workloads precisely when they most need to say
	# "skipped, no cluster".
	if [ "${1:-}" = "--list" ]; then
		if [ "${2:-}" = "--discover-flux" ] || [ "${2:-}" = "--flux" ]; then
			load_flux_workloads
		fi
		local entry w ns c
		for entry in "${WORKLOAD_TOPOLOGY[@]}"; do
			IFS='|' read -r w ns c <<<"$entry"
			printf '%s\t%s\n' "$w" "$ns"
		done
		return 0
	fi

	local requested=("$@")
	if [ "${#requested[@]}" -eq 0 ]; then
		mapfile -t requested < <(source_id_workloads)
	elif [ "${requested[0]}" = "--discover-flux" ] || [ "${requested[0]}" = "--flux" ]; then
		load_flux_workloads
		requested=()
		local entry w ns c
		for entry in "${WORKLOAD_TOPOLOGY[@]}"; do
			IFS='|' read -r w ns c <<<"$entry"
			requested+=("$w")
		done
	fi
	# `mapfile -t arr < <(cmd)` reports MAPFILE's status, never cmd's. mapfile
	# succeeds having read zero lines from a command that failed outright, so an
	# errored or relocated source_id_workloads left `requested` empty, the
	# per-workload loop below ran ZERO times, DRIFT and UNVERIFIED both stayed 0,
	# and this script printed "every checked workload is running the current
	# working tree" having checked nothing at all.
	#
	# That is the degenerate case of the failure this guard has already been
	# caught committing once: it reported VERIFIED FRESH while a 25-hour-stale
	# portal served 404s — truthfully, about a list that did not contain it (see
	# the WORKLOAD_TOPOLOGY note above). An empty list is that same list narrowed
	# all the way down, and it must not be the quietest outcome of the three.
	#
	# CANNOT VERIFY rather than DRIFT, deliberately: nothing has been shown to be
	# stale. The question was not answered.
	if [ "${#requested[@]}" -eq 0 ]; then
		printf '\n'
		unk "CANNOT VERIFY: the workload list came back EMPTY — nothing would be checked."
		printf '           No claim is being made about the deployed workloads. This is NOT a pass.\n\n' >&2
		exit 2
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
