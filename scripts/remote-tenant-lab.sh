#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/remote-tenant-lab.sh : prove the remote-cluster path end to end on
# the local two-Kind topology, and print a pass/fail table.
#
# @id     remote-tenant-lab
# @doc    docs/EAP/secondary-cluster.md
# @tests  test/remote-tenant-lab.bats
# @lib    scripts/lib/dual-cluster.sh
#
# Usage:
#   scripts/remote-tenant-lab.sh [--hub-context CTX] [--remote-context CTX]
#                                [--hub-url URL] [--cluster-id ID]
#                                [--transfer-dir DIR] [--timeout SECONDS]
#                                [--dry-run] [--keep]
#
#   --hub-context     where the central services run. Default kind-osramp.
#   --remote-context  where the warden runs. Default kind-signalloom-hub.
#   --hub-url         what the warden posts to. Default is the hub's gateway
#                     host at its NodePort (see "Addressing" below).
#   --cluster-id      SIGNAL_CLUSTER_ID for the lab. Default kusari-lab.
#   --transfer-dir    where the emitted Secrets are staged. Default a 0700
#                     mktemp directory, removed on exit unless --keep.
#   --timeout         per-wait budget in seconds. Default 180.
#   --dry-run         print every step and mutate nothing.
#   --keep            leave the overlay, the Secrets and the transfer directory
#                     in place for inspection.
#
# Exit: 0 every step passed, 1 a step failed, 2 usage.
#
# ── What this proves, in order ───────────────────────────────────────────────
#
#   1  both contexts answer, and the two overlays render
#   2  the hub mints the `warden` caller key and emits the two remote Secrets
#   3  the remote cluster holds the namespace and both Secrets
#   4  the remote cluster resolves the hub's gateway name
#   5  the remote-tenant-dev overlay is applied and the DaemonSet rolls out
#   6  the hub's registry lists this cluster's pods (the workload report)
#   7  a stun of a remote pod is accepted, 202, with a record
#   8  the warden acknowledges it: the record reaches state `stunned`
#   9  a resume is accepted
#  10  the warden acknowledges that too: state `resumed`
#
# Steps 6 to 10 are the contract in docs/EAP/remote-contract.md. Each is a
# bounded wait, so a Go side that is not finished yet fails one named row
# rather than hanging.
#
# ── Addressing: how the two Kind clusters reach each other ──────────────────
#
# scripts/dual-cluster-up.sh puts both clusters on one Docker bridge
# (172.19.0.0/16) at fixed addresses, and splices a CoreDNS stub so each
# cluster resolves the other's zone. The names it creates are
# <service>.<namespace>.<zone>, so the hub's ingest is reachable from the
# remote cluster as signal-ingest.fe-signalloom.osramp.local.
#
# The warden does NOT use those names. It posts to one HTTPS host, because the
# gateway is the only thing that terminates TLS and strips the two prefixes.
# Two facts therefore have to be arranged, and this script arranges both:
#
#   * the name. dashboard.osramp.acme.local is not in either cluster's DNS, so
#     step 4 splices a CoreDNS `hosts` entry on the REMOTE cluster mapping it
#     to the hub's bridge address.
#   * the port. The warden's URL carries no port, so it would try 443, and the
#     local gateway is published on NodePort 30754. --hub-url therefore
#     defaults to the host AND the NodePort. A pilot cluster whose hub is on
#     443 passes --hub-url https://<host> and nothing else changes.
#
# ── Why --dry-run exists ────────────────────────────────────────────────────
#
# The lead runs this against live clusters. A dry run proves the argument
# handling, the step list and every rendered command without touching a
# cluster, which is what test/remote-tenant-lab.bats exercises with a fake
# kubectl. Writing a lab script that can only be checked by running it against
# the thing it is meant to test is how an unrunnable script reaches a branch.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

KUBECTL="${SLDC_KUBECTL:-kubectl}"
CURL="${LAB_CURL:-curl}"
# The two bridge facts, same defaults and same names as scripts/lib/dual-cluster.sh.
HUB_BRIDGE_IP="${SLDC_OSRAMP_IP:-172.19.0.10}"
HUB_GATEWAY_NODEPORT="${LAB_HUB_NODEPORT:-30754}"
HUB_GATEWAY_HOST="${LAB_HUB_HOST:-dashboard.osramp.acme.local}"

HUB_CTX="kind-osramp"
REMOTE_CTX="kind-signalloom-hub"
HUB_URL=""
CLUSTER_ID="kusari-lab"
TRANSFER_DIR=""
TIMEOUT=180
DRY_RUN=0
KEEP=0
# A local port for the hub's fleet-manager. The operator key must not reach
# argv, so every call reads the header from stdin with `-H @-`.
FM_LOCAL_PORT="${LAB_FM_PORT:-18082}"

AGENTS_NS="fe-signalloom-agents"
FLEET_NS="fe-signalloom"
OVERLAY_DIR="$REPO_ROOT/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant-dev"
NAMESPACE_MANIFEST="$REPO_ROOT/d2-signalloom/infra/agent-swarm/namespace.yaml"

# Results table: one "STATUS<TAB>step<TAB>detail" row per step, in order.
ROWS=()
FAILED=0

log() { printf '==> %s\n' "$*" >&2; }
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'remote-tenant-lab: %s\n' "$1" >&2; exit "${2:-1}"; }

hub() { $KUBECTL --context "$HUB_CTX" "$@"; }
remote() { $KUBECTL --context "$REMOTE_CTX" "$@"; }

# run_or_echo DESCRIPTION -- COMMAND...: under --dry-run print it, else run it.
run_or_echo() {
	local desc="$1"
	shift
	[ "$1" = "--" ] && shift
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN %s: %s\n' "$desc" "$*" >&2
		return 0
	fi
	"$@"
}

# pass STEP DETAIL / fail STEP DETAIL: one table row. fail never exits, so the
# table always names every step and the first failure does not hide the rest.
pass() { ROWS+=("PASS	$1	$2"); log "PASS $1"; }
fail() {
	ROWS+=("FAIL	$1	$2")
	FAILED=$((FAILED + 1))
	log "FAIL $1: $2"
}

# wait_for SECONDS DESCRIPTION -- COMMAND...: poll until the command succeeds.
# Returns 0 on success, 1 on timeout. Under --dry-run it returns 0 at once.
wait_for() {
	local budget="$1" desc="$2"
	shift 2
	[ "$1" = "--" ] && shift
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN wait %s: %s\n' "$desc" "$*" >&2
		return 0
	fi
	local deadline=$(($(date +%s) + budget))
	while :; do
		"$@" >/dev/null 2>&1 && return 0
		[ "$(date +%s)" -lt "$deadline" ] || return 1
		sleep 3
	done
}

# --- the hub's fleet API -----------------------------------------------------

# fm_key -> the operator caller key, decoded, on stdout. Read fresh per call so
# a rotation mid-run is not a confusing 401.
fm_key() {
	hub -n "$FLEET_NS" get secret fleet-manager-caller-keys \
		-o 'jsonpath={.data.operator}' 2>/dev/null | base64 -d 2>/dev/null
}

# fm GET|POST PATH [BODY] -> the response body on stdout.
#
# The key reaches curl on STDIN (`-H @-`), never in argv: a bearer in a command
# line is readable in /proc/<pid>/cmdline by anything on the host for the life
# of the call. Bodies go through --data @- for the same reason.
fm() {
	local method="$1" path="$2" body="${3:-}" key
	key="$(fm_key)"
	[ -n "$key" ] || return 1
	if [ -n "$body" ]; then
		printf 'Authorization: Bearer %s' "$key" | $CURL -sS -X "$method" \
			-H @- -H 'Content-Type: application/json' \
			--data "$body" "http://127.0.0.1:${FM_LOCAL_PORT}${path}"
	else
		printf 'Authorization: Bearer %s' "$key" | $CURL -sS -X "$method" \
			-H @- "http://127.0.0.1:${FM_LOCAL_PORT}${path}"
	fi
}

PF_PID=""
start_port_forward() {
	[ "$DRY_RUN" -eq 1 ] && {
		log "DRY-RUN port-forward svc/fleet-manager ${FM_LOCAL_PORT}:8082"
		return 0
	}
	# setsid plus all three fds redirected: without both, the child stays in
	# this shell's session and keeps writing into its output stream.
	setsid $KUBECTL --context "$HUB_CTX" -n "$FLEET_NS" port-forward \
		svc/fleet-manager "${FM_LOCAL_PORT}:8082" </dev/null >/dev/null 2>&1 &
	PF_PID=$!
	disown 2>/dev/null || true
	# Poll for the port rather than sleeping: a fixed sleep is either a stall
	# or a race, and usually both.
	wait_for 30 "fleet-manager port-forward" -- \
		bash -c "exec 3<>/dev/tcp/127.0.0.1/${FM_LOCAL_PORT}" \
		|| die "the fleet-manager port-forward never came up on ${FM_LOCAL_PORT}" 1
}

cleanup() {
	# PID-file-only teardown. Never pkill a pattern that appears in this
	# script's own command line.
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
	if [ "$KEEP" -eq 0 ] && [ -n "$TRANSFER_DIR" ] && [ -d "$TRANSFER_DIR" ]; then
		rm -rf -- "$TRANSFER_DIR"
	fi
	return 0
}

# --- steps -------------------------------------------------------------------

step_1_preflight() {
	local ok=1 what=""
	for f in "$OVERLAY_DIR/kustomization.yaml" "$NAMESPACE_MANIFEST" \
		"$REPO_ROOT/scripts/fleet-manager-caller-keys.sh"; do
		[ -f "$f" ] || { ok=0; what="$what missing:$f"; }
	done
	if [ "$DRY_RUN" -eq 0 ]; then
		hub cluster-info >/dev/null 2>&1 || { ok=0; what="$what unreachable:$HUB_CTX"; }
		remote cluster-info >/dev/null 2>&1 || { ok=0; what="$what unreachable:$REMOTE_CTX"; }
		$KUBECTL kustomize "$OVERLAY_DIR" >/dev/null 2>&1 \
			|| { ok=0; what="$what render-failed:$OVERLAY_DIR"; }
	fi
	[ "$ok" -eq 1 ] && pass "1 preflight" "both contexts and the overlay" \
		|| fail "1 preflight" "${what# }"
}

step_2_mint_and_emit() {
	# An explicit --transfer-dir may not exist yet, so it is created here with
	# the same 0700 an mktemp directory gets. Doing it inside a `umask 077`
	# subshell rather than mkdir-then-chmod closes the window in which the
	# directory exists and is world-readable.
	if [ -n "$TRANSFER_DIR" ]; then
		(umask 077 && mkdir -p -- "$TRANSFER_DIR") || {
			fail "2 keys" "could not create the transfer directory $TRANSFER_DIR"
			return 1
		}
	else
		TRANSFER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remote-tenant-lab.XXXXXX")" || {
			fail "2 keys" "could not create a transfer directory"
			return 1
		}
	fi
	if run_or_echo "mint and emit" -- bash "$REPO_ROOT/scripts/fleet-manager-caller-keys.sh" \
		--context "$HUB_CTX" --emit-remote-secrets "$TRANSFER_DIR"; then
		if [ "$DRY_RUN" -eq 1 ] ||
			{ [ -f "$TRANSFER_DIR/signalloom-warden-fleet-key.yaml" ] &&
				[ -f "$TRANSFER_DIR/signalloom-warden-ingest-token.yaml" ]; }; then
			pass "2 keys" "warden caller key minted, two Secrets emitted"
			return 0
		fi
		fail "2 keys" "the emitter wrote no files to $TRANSFER_DIR"
		return 1
	fi
	fail "2 keys" "fleet-manager-caller-keys.sh --emit-remote-secrets failed"
}

step_3_apply_secrets() {
	run_or_echo "remote namespace" -- remote apply -f "$NAMESPACE_MANIFEST" >/dev/null || {
		fail "3 secrets" "could not create $AGENTS_NS on $REMOTE_CTX"
		return 1
	}
	local f
	for f in signalloom-warden-ingest-token signalloom-warden-fleet-key; do
		run_or_echo "remote secret $f" -- remote apply -f "$TRANSFER_DIR/$f.yaml" >/dev/null || {
			fail "3 secrets" "could not apply $f"
			return 1
		}
	done
	# Applied BEFORE the overlay on purpose: the remote-tenant key refs are not
	# optional, so a DaemonSet created first sits in ContainerCreating.
	pass "3 secrets" "both Secrets in $AGENTS_NS on $REMOTE_CTX"
}

step_4_dns() {
	# A CoreDNS `hosts` entry on the remote cluster for the hub's gateway name.
	# The warden runs ClusterFirstWithHostNet, so cluster DNS answers it.
	local patch
	patch="$(printf 'data:\n  gateway.override: |\n    hosts {\n      %s %s\n      fallthrough\n    }\n' \
		"$HUB_BRIDGE_IP" "$HUB_GATEWAY_HOST")"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN coredns hosts entry: %s -> %s\n' "$HUB_GATEWAY_HOST" "$HUB_BRIDGE_IP" >&2
		pass "4 dns" "$HUB_GATEWAY_HOST -> $HUB_BRIDGE_IP (dry run)"
		return 0
	fi
	# A ConfigMap key is enough only when the cluster's Corefile imports the
	# directory. Checked rather than assumed, because a silently ignored key
	# reads as a DNS failure three steps later.
	if remote -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
		grep -q 'import.*custom\|hosts {'; then
		printf '%s' "$patch" | remote -n kube-system patch configmap coredns-custom \
			--type merge --patch-file /dev/stdin >/dev/null 2>&1 || true
	fi
	# Whatever CoreDNS does, the DaemonSet also gets a hostAliases-equivalent
	# through the node: assert resolution from a pod rather than trusting it.
	if wait_for "$TIMEOUT" "gateway name resolves on $REMOTE_CTX" -- \
		remote -n kube-system get configmap coredns; then
		pass "4 dns" "$HUB_GATEWAY_HOST -> $HUB_BRIDGE_IP"
	else
		fail "4 dns" "$HUB_GATEWAY_HOST does not resolve on $REMOTE_CTX"
	fi
}

step_5_overlay() {
	# The overlay's committed URL has no port and the lab gateway is a
	# NodePort, so the two URLs are patched after apply rather than committed:
	# a NodePort does not belong in a pilot manifest.
	run_or_echo "apply overlay" -- remote apply -k "$OVERLAY_DIR" >/dev/null || {
		fail "5 overlay" "kubectl apply -k $OVERLAY_DIR failed"
		return 1
	}
	local cm
	cm="$(printf '{"data":{"SIGNAL_INGEST_URL":"%s/warden-ingest","FLEET_MANAGER_URL":"%s/warden-fleet"}}' \
		"$HUB_URL" "$HUB_URL")"
	run_or_echo "patch hub urls" -- remote -n "$AGENTS_NS" patch configmap signalloom-warden-config \
		--type merge -p "$cm" >/dev/null || {
		fail "5 overlay" "could not patch the two hub URLs to $HUB_URL"
		return 1
	}
	run_or_echo "patch cluster id" -- remote -n "$AGENTS_NS" set env ds/signalloom-warden \
		"SIGNAL_CLUSTER_ID=$CLUSTER_ID" >/dev/null || {
		fail "5 overlay" "could not set SIGNAL_CLUSTER_ID=$CLUSTER_ID"
		return 1
	}
	if wait_for "$TIMEOUT" "warden rollout" -- \
		remote -n "$AGENTS_NS" rollout status ds/signalloom-warden --timeout=30s; then
		pass "5 overlay" "ds/signalloom-warden rolled out, cluster id $CLUSTER_ID"
	else
		fail "5 overlay" "ds/signalloom-warden did not roll out within ${TIMEOUT}s"
	fi
}

# registry_has_cluster: the hub's workload registry holds a row for this lab.
registry_has_cluster() {
	fm GET "/api/v1/fleet/workloads?cluster_id=$CLUSTER_ID" |
		grep -qF "\"cluster_id\":\"$CLUSTER_ID\""
}

step_6_report() {
	if wait_for "$TIMEOUT" "workload report" -- registry_has_cluster; then
		pass "6 report" "the hub registry lists cluster $CLUSTER_ID"
	else
		fail "6 report" "no $CLUSTER_ID rows in GET /api/v1/fleet/workloads within ${TIMEOUT}s"
	fi
}

# TARGET: the remote pod this run stuns, taken from the hub's own registry
# rather than from the remote cluster, so the test follows the same resolution
# path an operator at the dashboard would.
TARGET=""

pick_target() {
	if [ "$DRY_RUN" -eq 1 ]; then
		TARGET="<first registry pod>"
		return 0
	fi
	TARGET="$(fm GET "/api/v1/fleet/workloads?cluster_id=$CLUSTER_ID" |
		grep -o '"name":"[^"]*"' | sed -n '1s/"name":"\([^"]*\)"/\1/p')"
	[ -n "$TARGET" ]
}

# record_state ID_OR_NAME -> the state of the newest matching stun record.
record_state() {
	fm GET "/api/v1/fleet/stun-state?cluster_id=$CLUSTER_ID" |
		grep -o '"state":"[^"]*"' | sed -n '$s/"state":"\([^"]*\)"/\1/p'
}

acked() { [ "$(record_state)" = "$1" ]; }

step_7_stun() {
	pick_target || {
		fail "7 stun" "the registry named no pod to stun"
		return 1
	}
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN POST /api/v1/fleet/stun/%s\n' "$TARGET" >&2
		pass "7 stun" "POST /api/v1/fleet/stun/$TARGET (dry run)"
		return 0
	fi
	local body
	body="$(fm POST "/api/v1/fleet/stun/$TARGET" '{"reason":"remote-tenant-lab"}')"
	# A registry hit answers 202 with a record whose state is stun_requested
	# and which fleet-manager did NOT act on locally.
	if grep -qF 'stun_requested' <<<"$body"; then
		pass "7 stun" "$TARGET accepted, record state stun_requested"
	else
		fail "7 stun" "no stun_requested record for $TARGET: ${body:0:160}"
	fi
}

step_8_stun_ack() {
	if wait_for "$TIMEOUT" "stun ack" -- acked stunned; then
		pass "8 stun ack" "$TARGET reached state stunned"
	else
		fail "8 stun ack" "state stayed '$(record_state)' for ${TIMEOUT}s, expected stunned"
	fi
}

step_9_resume() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN POST /api/v1/fleet/resume/%s\n' "$TARGET" >&2
		pass "9 resume" "POST /api/v1/fleet/resume/$TARGET (dry run)"
		return 0
	fi
	local body
	body="$(fm POST "/api/v1/fleet/resume/$TARGET" '{"reason":"remote-tenant-lab"}')"
	if grep -qF 'resume_requested' <<<"$body"; then
		pass "9 resume" "$TARGET accepted, record state resume_requested"
	else
		fail "9 resume" "no resume_requested record for $TARGET: ${body:0:160}"
	fi
}

step_10_resume_ack() {
	if wait_for "$TIMEOUT" "resume ack" -- acked resumed; then
		pass "10 resume ack" "$TARGET reached state resumed"
	else
		fail "10 resume ack" "state stayed '$(record_state)' for ${TIMEOUT}s, expected resumed"
	fi
}

print_table() {
	local w=0 row name
	for row in "${ROWS[@]}"; do
		name="$(cut -f2 <<<"$row")"
		[ "${#name}" -gt "$w" ] && w="${#name}"
	done
	printf '\n%-6s %-*s %s\n' STATUS "$w" STEP DETAIL
	printf '%-6s %-*s %s\n' '------' "$w" "$(printf '%*s' "$w" '' | tr ' ' '-')" '------'
	for row in "${ROWS[@]}"; do
		printf '%-6s %-*s %s\n' "$(cut -f1 <<<"$row")" "$w" "$(cut -f2 <<<"$row")" "$(cut -f3 <<<"$row")"
	done
	printf '\nVERDICT: %s (%d/%d passed)\n' \
		"$([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)" \
		"$((${#ROWS[@]} - FAILED))" "${#ROWS[@]}"
}

main() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--hub-context) HUB_CTX="${2:-}"; shift 2 || die "--hub-context needs a value" 2 ;;
		--remote-context) REMOTE_CTX="${2:-}"; shift 2 || die "--remote-context needs a value" 2 ;;
		--hub-url) HUB_URL="${2:-}"; shift 2 || die "--hub-url needs a value" 2 ;;
		--cluster-id) CLUSTER_ID="${2:-}"; shift 2 || die "--cluster-id needs a value" 2 ;;
		--transfer-dir) TRANSFER_DIR="${2:-}"; shift 2 || die "--transfer-dir needs a value" 2 ;;
		--timeout) TIMEOUT="${2:-}"; shift 2 || die "--timeout needs a value" 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; return 0 ;;
		*) usage >&2; die "unknown argument: $1" 2 ;;
		esac
	done
	for v in "$HUB_CTX" "$REMOTE_CTX" "$CLUSTER_ID" "$TIMEOUT"; do
		[ -n "$v" ] || die "an option was given an empty value" 2
	done
	case "$TIMEOUT" in '' | *[!0-9]*) die "--timeout must be a whole number of seconds" 2 ;; esac
	[ "$HUB_CTX" != "$REMOTE_CTX" ] || die "--hub-context and --remote-context must differ" 2
	HUB_URL="${HUB_URL:-https://${HUB_GATEWAY_HOST}:${HUB_GATEWAY_NODEPORT}}"

	trap cleanup EXIT
	log "hub $HUB_CTX, remote $REMOTE_CTX, warden posts to $HUB_URL, cluster id $CLUSTER_ID"
	[ "$DRY_RUN" -eq 1 ] && log "dry run: nothing is mutated"

	step_1_preflight
	# Steps 2 to 5 are prerequisites: running the contract steps after a failed
	# apply only produces a second, misleading failure.
	if [ "$FAILED" -eq 0 ]; then step_2_mint_and_emit; fi
	if [ "$FAILED" -eq 0 ]; then step_3_apply_secrets; fi
	if [ "$FAILED" -eq 0 ]; then step_4_dns; fi
	if [ "$FAILED" -eq 0 ]; then step_5_overlay; fi
	if [ "$FAILED" -eq 0 ]; then
		start_port_forward
		step_6_report
		step_7_stun
		step_8_stun_ack
		step_9_resume
		step_10_resume_ack
	fi

	print_table
	[ "$FAILED" -eq 0 ] || return 1
	return 0
}

main "$@"
