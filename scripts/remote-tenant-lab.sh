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
# @lib    scripts/lib/dual-cluster.sh, scripts/lib/keys.sh
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
#   --load-kind-image load the overlay's warden image into the remote Kind
#                     node before applying (the canonical ghcr.io name is not
#                     published; a Kind remote can only have it loaded)
#                     in place for inspection.
#
# Exit: 0 every step passed, 1 a step failed, 2 usage.
#
# ── What this proves, in order ───────────────────────────────────────────────
#
#   1  both contexts answer, and the two overlays render
#   2  the hub mints the `warden` caller key, emits the two remote Secrets,
#      and holds the two operator keypairs (scripts/fleet-operator-keys.sh)
#   3  the remote cluster holds the namespace and both Secrets
#  3b  the APPLIANCE_MODE=attached preflight accepts those Secrets (OSD-8:
#      central issuance is a prerequisite of attached mode, and the gate that
#      enforces it is scripts/attached-mode-preflight.sh)
#   4  the remote cluster resolves the hub's gateway name
#   5  the remote-tenant-dev overlay is applied and the DaemonSet rolls out
#   6  the hub's registry lists this cluster's pods (the workload report)
#   7  a stun of a remote pod is accepted, 202, with a record
#   8  the warden acknowledges it: the record reaches state `stunned`
#   9  a resume carrying a token signed by both operators is accepted, 202
#  9b  the same token with a different idempotency key is refused, 409
#  10  the warden acknowledges the resume: state `resumed`
#
# Steps 6 to 10 are the contract in docs/EAP/remote-contract.md. Each is a
# bounded wait, so a Go side that is not finished yet fails one named row
# rather than hanging.
#
# ── The resume token ────────────────────────────────────────────────────────
#
# A remote resume is governed exactly like a local one: fleet-manager accepts
# POST /api/v1/fleet/resume/<name> only with a token (resume_token.go) minted
# for that agent, for the audience and trust root its own Deployment names,
# and signed by enough operators whose public keys it loaded from ConfigMap
# fe-signalloom/fleet-manager-operator-keys. Step 9 mints, signs and posts
# one with fleet-manager's cmd/resume-token, using the private keys under
# <keys_dir>/fleet-operators/ that step 2 ensures. Private keys reach the
# tool as FILE PATHS, never as values. Step 9b proves the replay ledger: the
# consumed token, presented again under another idempotency key, is 409.
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
#     hub gateway is published on a NodePort (discovered from the Envoy
#     Gateway Service, 30476 on the local lab). --hub-url therefore
#     defaults to the host AND that NodePort. A pilot cluster whose hub is on
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
# shellcheck source=scripts/lib/keys.sh
. "$SCRIPT_DIR/lib/keys.sh"

KUBECTL="${SLDC_KUBECTL:-kubectl}"
CURL="${LAB_CURL:-curl}"
# The two bridge facts, same defaults and same names as scripts/lib/dual-cluster.sh.
HUB_BRIDGE_IP="${SLDC_OSRAMP_IP:-172.19.0.10}"
# Discovered from the hub's Envoy Gateway Service in main(); 30754 is the host
# port-forward and is not reachable from another cluster.
HUB_GATEWAY_NODEPORT="${LAB_HUB_NODEPORT:-}"
HUB_GATEWAY_HOST="${LAB_HUB_HOST:-dashboard.osramp.acme.local}"

HUB_CTX="kind-osramp"
REMOTE_CTX="kind-signalloom-hub"
HUB_URL=""
CLUSTER_ID="kusari-lab"
TRANSFER_DIR=""
TIMEOUT=180
DRY_RUN=0
KEEP=0
LOAD_KIND_IMAGE=0
# A local port for the hub's fleet-manager. The operator key must not reach
# argv, so every call reads the header from stdin with `-H @-`.
FM_LOCAL_PORT="${LAB_FM_PORT:-18082}"

AGENTS_NS="fe-signalloom-agents"
FLEET_NS="fe-signalloom"
# The resume-governance operators step 9 signs with. scripts/fleet-operator-keys.sh
# mints them under <keys_dir>/fleet-operators/ and publishes the public halves.
OPKEYS_DIR="${LAB_OPERATOR_KEYS_DIR:-$(keys_dir_abs "$REPO_ROOT")/fleet-operators}"
LAB_OPERATORS=(alice bob)
OPERATOR_PREFIX="spiffe://signalloom.demo/operator/"
FM_DIR="$REPO_ROOT/d2-signalloom/apps/fleet-manager"
# What the dry run assumes the hub Deployment names; the live run READS them.
FLEET_AUDIENCE_DEFAULT="signalloom-fleet/local"
TRUST_ROOT_DEFAULT="signalloom-operators-v1"
OVERLAY_DIR="$REPO_ROOT/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant-dev"
NAMESPACE_MANIFEST="$REPO_ROOT/d2-signalloom/infra/agent-swarm/namespace.yaml"
# The warden runs in its own namespace, and its two Secrets (emitted for that
# namespace) must exist before the overlay, so step 3 creates it first.
WARDEN_NS="inf-signalloom-warden"
WARDEN_NS_DIR="$REPO_ROOT/d2-signalloom/infra/agent-swarm/signalloom-warden-namespace"

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
	ensure_port_forward
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

# fm_file METHOD PATH DATAFILE BODYOUT -> the HTTP status on stdout, the
# response body in BODYOUT. The body is read by curl from DATAFILE (`@file`),
# so a signed token is never an argv element either.
fm_file() {
	local method="$1" path="$2" datafile="$3" bodyout="$4" key
	ensure_port_forward
	key="$(fm_key)"
	[ -n "$key" ] || return 1
	printf 'Authorization: Bearer %s' "$key" | $CURL -sS -o "$bodyout" -w '%{http_code}' \
		-X "$method" -H @- -H 'Content-Type: application/json' \
		--data "@$datafile" "http://127.0.0.1:${FM_LOCAL_PORT}${path}"
}

# fm_deploy_env NAME -> the value the hub's fleet-manager Deployment sets for
# env NAME, so the token names the audience and trust root the verifier holds
# rather than whatever this script assumed.
fm_deploy_env() {
	hub -n "$FLEET_NS" get deploy fleet-manager \
		-o "jsonpath={.spec.template.spec.containers[?(@.name=='fleet-manager')].env[?(@.name=='$1')].value}" 2>/dev/null
}

# resume_token ARGS...: fleet-manager's cmd/resume-token, the binary
# scripts/fleet-operator-keys.sh built next to the keys when it has, else
# `go run` from the module.
resume_token() {
	if [ -x "$OPKEYS_DIR/resume-token" ]; then
		"$OPKEYS_DIR/resume-token" "$@"
	else
		(cd "$FM_DIR" && go run ./cmd/resume-token "$@")
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

# ensure_port_forward: a kubectl port-forward dies quietly when its pod rolls
# or the API connection drops, and the next request then reads as a lab
# failure. Re-establish it when nothing listens on the local port.
ensure_port_forward() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	if bash -c "exec 3<>/dev/tcp/127.0.0.1/${FM_LOCAL_PORT}" 2>/dev/null; then
		return 0
	fi
	log "fleet-manager port-forward is gone; re-establishing"
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
	PF_PID=""
	start_port_forward
}

cleanup() {
	# PID-file-only teardown. Never pkill a pattern that appears in this
	# script's own command line.
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
	if [ "$KEEP" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
		remote -n "$AGENTS_NS" delete deployment "$LAB_TARGET_NAME" --ignore-not-found >/dev/null 2>&1 || true
	fi
	if [ "$KEEP" -eq 0 ] && [ -n "$TRANSFER_DIR" ] && [ -d "$TRANSFER_DIR" ]; then
		rm -rf -- "$TRANSFER_DIR"
	fi
	return 0
}

# --- steps -------------------------------------------------------------------

step_1_preflight() {
	local ok=1 what=""
	for f in "$OVERLAY_DIR/kustomization.yaml" "$NAMESPACE_MANIFEST" "$WARDEN_NS_DIR/kustomization.yaml" \
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
			ensure_operator_keys || return 1
			pass "2 keys" "warden caller key minted, two Secrets emitted, operator keys ${LAB_OPERATORS[*]} in place"
			return 0
		fi
		fail "2 keys" "the emitter wrote no files to $TRANSFER_DIR"
		return 1
	fi
	fail "2 keys" "fleet-manager-caller-keys.sh --emit-remote-secrets failed"
}

# ensure_operator_keys: the two operator keypairs step 9 signs with, and the
# hub ConfigMap of their public halves. The script is idempotent, so it runs
# whenever a keypair is absent locally and ALSO when the ConfigMap may be: a
# fresh hub with stale local keys would otherwise verify against nothing.
# fleet-manager reads the ConfigMap at start, so a newly created key set is
# followed by a rollout restart before any resume is attempted.
ensure_operator_keys() {
	local n out
	if [ "$DRY_RUN" -eq 1 ]; then
		run_or_echo "operator keys (when absent)" -- bash "$REPO_ROOT/scripts/fleet-operator-keys.sh" --context "$HUB_CTX"
		return 0
	fi
	out="$(bash "$REPO_ROOT/scripts/fleet-operator-keys.sh" --context "$HUB_CTX" </dev/null)" || {
		fail "2 keys" "scripts/fleet-operator-keys.sh --context $HUB_CTX failed"
		return 1
	}
	for n in "${LAB_OPERATORS[@]}"; do
		[ -s "$OPKEYS_DIR/$n.key" ] || {
			fail "2 keys" "no private key for operator $n at $OPKEYS_DIR/$n.key"
			return 1
		}
	done
	case "$out" in
	*"created:"*)
		log "operator keys were created; restarting the hub fleet-manager so it loads them"
		hub -n "$FLEET_NS" rollout restart deploy/fleet-manager >/dev/null 2>&1 || true
		wait_for "$TIMEOUT" "fleet-manager rollout after operator keys" -- \
			hub -n "$FLEET_NS" rollout status deploy/fleet-manager --timeout=30s ||
			{ fail "2 keys" "fleet-manager did not roll out after the operator keys were created"; return 1; }
		;;
	esac
	return 0
}

step_3_apply_secrets() {
	run_or_echo "remote namespace" -- remote apply -f "$NAMESPACE_MANIFEST" >/dev/null || {
		fail "3 secrets" "could not create $AGENTS_NS on $REMOTE_CTX"
		return 1
	}
	run_or_echo "remote warden namespace" -- remote apply -k "$WARDEN_NS_DIR" >/dev/null || {
		fail "3 secrets" "could not create $WARDEN_NS on $REMOTE_CTX"
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
	pass "3 secrets" "both Secrets in $WARDEN_NS on $REMOTE_CTX"
}

# step_3b: the APPLIANCE_MODE=attached gate (OSD-8), run against the Secrets
# step_3 just applied. The lab is the one place that can prove the gate both
# ways round: step_3 is the only local source of those Secrets, so a preflight
# that fails here means the emitter, the transfer or the apply is wrong, and a
# preflight that passes here is the same assertion a design partner's appliance
# makes before it renders the overlay.
#
# It is a row of its own rather than a line inside step_3 because the two
# failures are different: step_3 fails when an apply fails, this fails when the
# applied objects do not satisfy the overlay's required key refs.
step_3b_attached_preflight() {
	local script="$REPO_ROOT/scripts/attached-mode-preflight.sh"
	[ -x "$script" ] || {
		fail "3b attached preflight" "missing or not executable: $script"
		return 1
	}
	if run_or_echo "attached preflight" -- env APPLIANCE_MODE=attached \
		bash "$script" --context "$REMOTE_CTX" --namespace "$WARDEN_NS" \
		--kubectl "$KUBECTL"; then
		pass "3b attached preflight" "the attached-mode gate accepts $WARDEN_NS on $REMOTE_CTX"
		return 0
	fi
	fail "3b attached preflight" "the attached-mode gate rejected $WARDEN_NS on $REMOTE_CTX"
}

step_4_dns() {
	# A CoreDNS `hosts` block on the remote cluster for the hub's gateway name.
	# The warden runs ClusterFirstWithHostNet, so CoreDNS answers it; without
	# the block CoreDNS forwards upstream and the host's own /etc/hosts (a
	# tailnet address, say) comes back, which the Kind node cannot reach.
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN coredns hosts entry: %s -> %s\n' "$HUB_GATEWAY_HOST" "$HUB_BRIDGE_IP" >&2
		pass "4 dns" "$HUB_GATEWAY_HOST -> $HUB_BRIDGE_IP (dry run)"
		return 0
	fi
	local corefile block
	corefile="$(remote -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
	[ -n "$corefile" ] || { fail "4 dns" "could not read the remote Corefile"; return 0; }
	block="    hosts lab-hub-gateway {\n       $HUB_BRIDGE_IP $HUB_GATEWAY_HOST\n       fallthrough\n    }"
	if ! grep -q "$HUB_BRIDGE_IP $HUB_GATEWAY_HOST" <<<"$corefile"; then
		# Insert the block right after the `ready` line of the .:53 server; the
		# hosts plugin must precede forward, and `ready` always sits before it.
		corefile="$(printf '%s' "$corefile" | awk -v blk="$block" 'done==0 && /^    ready$/ {print; gsub(/\\n/, "\n", blk); print blk; done=1; next} {print}')"
		grep -q 'lab-hub-gateway' <<<"$corefile" || { fail "4 dns" "could not place the hosts block in the Corefile"; return 0; }
		remote -n kube-system create configmap coredns --from-literal=Corefile="$corefile" --dry-run=client -o yaml \
			| remote -n kube-system apply -f - >/dev/null || { fail "4 dns" "could not update the remote Corefile"; return 0; }
		remote -n kube-system rollout restart deployment/coredns >/dev/null 2>&1 || true
		remote -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null 2>&1 || true
	fi
	# Prove it from a pod rather than trusting the ConfigMap.
	if wait_for "$TIMEOUT" "$HUB_GATEWAY_HOST resolves to $HUB_BRIDGE_IP on $REMOTE_CTX" -- \
		sh -c "$KUBECTL --context '$REMOTE_CTX' -n kube-system run lab-dns-\$\$ --rm -i --restart=Never --image=busybox:1.36 --command -- nslookup '$HUB_GATEWAY_HOST' 2>/dev/null | grep -q '$HUB_BRIDGE_IP'"; then
		pass "4 dns" "$HUB_GATEWAY_HOST -> $HUB_BRIDGE_IP"
	else
		fail "4 dns" "$HUB_GATEWAY_HOST does not resolve to $HUB_BRIDGE_IP on $REMOTE_CTX"
	fi
}

# load_warden_image: the overlay names the canonical ghcr.io image, which is
# built locally and never pushed, so a Kind remote has to have it loaded
# (imagePullPolicy IfNotPresent then finds it). Only with --load-kind-image.
load_warden_image() {
	[ "${LOAD_KIND_IMAGE:-0}" -eq 1 ] || return 0
	local img name
	img="$($KUBECTL kustomize "$OVERLAY_DIR" 2>/dev/null | grep -o 'ghcr.io/[^ "]*signalloom-warden:[^ "]*' | head -1)"
	[ -n "$img" ] || { fail "5 overlay" "could not read the warden image from $OVERLAY_DIR"; return 1; }
	name="${REMOTE_CTX#kind-}"
	docker exec "${name}-control-plane" crictl rmi "$img" >/dev/null 2>&1 || true
	if [ -x "${SCRIPT_DIR}/kind-load-verified.sh" ]; then
		run_or_echo "kind-load-verified $img into $name" -- env CLUSTER_NAME="$name" "${SCRIPT_DIR}/kind-load-verified.sh" "$img" >/dev/null || {
			fail "5 overlay" "kind-load-verified.sh $img into $name failed"; return 1; }
	else
		run_or_echo "kind load $img into $name" -- kind load docker-image "$img" --name "$name" >/dev/null || {
			fail "5 overlay" "kind load docker-image $img --name $name failed"; return 1; }
	fi
	log "loaded $img into kind cluster $name"
}

step_5_overlay() {
	load_warden_image || return 0
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
	run_or_echo "patch hub urls" -- remote -n "$WARDEN_NS" patch configmap signalloom-warden-config \
		--type merge -p "$cm" >/dev/null || {
		fail "5 overlay" "could not patch the two hub URLs to $HUB_URL"
		return 1
	}
	run_or_echo "patch cluster id" -- remote -n "$WARDEN_NS" set env ds/signalloom-warden \
		"SIGNAL_CLUSTER_ID=$CLUSTER_ID" >/dev/null || {
		fail "5 overlay" "could not set SIGNAL_CLUSTER_ID=$CLUSTER_ID"
		return 1
	}
	if wait_for "$TIMEOUT" "warden rollout" -- \
		remote -n "$WARDEN_NS" rollout status ds/signalloom-warden --timeout=30s; then
		pass "5 overlay" "ds/signalloom-warden rolled out, cluster id $CLUSTER_ID"
	else
		fail "5 overlay" "ds/signalloom-warden did not roll out within ${TIMEOUT}s"
	fi
}

# registry_has_cluster: the hub's workload registry holds a row for this lab.
# registry_has_cluster: the hub lists the pod step 5b created (or, with no
# seeded pod, any pod of the cluster).
registry_has_cluster() {
	local body
	body="$(fm GET "/api/v1/fleet/workloads?cluster_id=$CLUSTER_ID")"
	if [ -n "${LAB_TARGET_POD:-}" ]; then
		grep -qF "\"name\":\"$LAB_TARGET_POD\"" <<<"$body"
	else
		grep -qF "\"cluster_id\":\"$CLUSTER_ID\"" <<<"$body"
	fi
}

# step_5b: a workload for the warden to report and the hub to stun. The lab
# cluster runs no agent, so it gets one: a sleeper labelled as an agent in the
# watched namespace. Removed by cleanup unless --keep.
LAB_TARGET_NAME="lab-agent"
LAB_TARGET_POD=""
step_5b_target() {
	if [ "$DRY_RUN" -eq 1 ]; then
		pass "5b target" "deployment/$LAB_TARGET_NAME labelled signalloom.ai/agent=true (dry run)"
		return 0
	fi
	if ! printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    signalloom.ai/agent: "true"\n    app.kubernetes.io/name: %s\nspec:\n  replicas: 1\n  selector:\n    matchLabels:\n      app.kubernetes.io/name: %s\n  template:\n    metadata:\n      labels:\n        signalloom.ai/agent: "true"\n        app.kubernetes.io/name: %s\n    spec:\n      containers:\n        - name: agent\n          image: busybox:1.36\n          command: ["sh", "-c", "while true; do sleep 5; done"]\n' \
		"$LAB_TARGET_NAME" "$AGENTS_NS" "$LAB_TARGET_NAME" "$LAB_TARGET_NAME" "$LAB_TARGET_NAME" \
		| remote apply -f - >/dev/null; then
		fail "5b target" "could not create deployment/$LAB_TARGET_NAME on $REMOTE_CTX"; return 0
	fi
	if wait_for "$TIMEOUT" "lab target rollout" -- remote -n "$AGENTS_NS" rollout status deployment/"$LAB_TARGET_NAME" --timeout=30s; then
		# The pod THIS run created. A previous run's pod can still be in the
		# registry while it terminates, and stunning that one ends in a 404 at
		# resume once its entry is gone (lab run 2, 2026-10-04).
		# A terminating pod keeps phase Running, so the selector is not enough:
		# exclude anything with a deletionTimestamp and take the newest.
		LAB_TARGET_POD="$(remote -n "$AGENTS_NS" get pods -l app.kubernetes.io/name="$LAB_TARGET_NAME" \
			--sort-by=.metadata.creationTimestamp \
			-o custom-columns='NAME:.metadata.name,DEL:.metadata.deletionTimestamp' --no-headers 2>/dev/null \
			| awk '$2 == "<none>" { name = $1 } END { print name }')"
		[ -n "$LAB_TARGET_POD" ] || { fail "5b target" "no Running pod for deployment/$LAB_TARGET_NAME"; return 0; }
		pass "5b target" "deployment/$LAB_TARGET_NAME running as pod $LAB_TARGET_POD in $AGENTS_NS on $REMOTE_CTX"
	else
		fail "5b target" "deployment/$LAB_TARGET_NAME did not become ready within ${TIMEOUT}s"
	fi
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
	if [ -n "${LAB_TARGET_POD:-}" ]; then
		TARGET="$LAB_TARGET_POD"
		return 0
	fi
	TARGET="$(fm GET "/api/v1/fleet/workloads?cluster_id=$CLUSTER_ID" |
		grep -o '"name":"[^"]*"' | sed -n '1s/"name":"\([^"]*\)"/\1/p')"
	[ -n "$TARGET" ]
}

# record_state ID_OR_NAME -> the state of the newest matching stun record.
# record_state -> the state of THIS lab's stun record. The default stun-state
# view lists only records the warden still has to act on, so an acked record
# leaves it; include=all shows every record of the cluster and the lab's own
# id selects one.
RECORD_ID=""
record_state() {
	fm GET "/api/v1/fleet/stun-state?cluster_id=$CLUSTER_ID&include=all" |
		grep -o "{[^{}]*\"id\":\"$RECORD_ID\"[^{}]*}" | head -1 |
		grep -o '"state":"[^"]*"' | sed -n '1s/"state":"\([^"]*\)"/\1/p'
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
		RECORD_ID="$(grep -o '"id":"[^"]*"' <<<"$body" | head -1 | sed 's/"id":"\([^"]*\)"/\1/')"
		pass "7 stun" "$TARGET accepted, record $RECORD_ID state stun_requested"
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

# The token, the request body and the responses live in TRANSFER_DIR (0700,
# removed on exit unless --keep) next to the emitted Secrets.
RESUME_TOKEN_FILE=""
RESUME_REQUEST_FILE=""

step_9_resume() {
	RESUME_TOKEN_FILE="$TRANSFER_DIR/resume-token.json"
	RESUME_REQUEST_FILE="$TRANSFER_DIR/resume-request.json"
	local aud root n
	if [ "$DRY_RUN" -eq 1 ]; then
		aud="$FLEET_AUDIENCE_DEFAULT"
		root="$TRUST_ROOT_DEFAULT"
		printf 'DRY-RUN read FLEET_AUDIENCE and OPERATOR_TRUST_ROOT_ID from deploy/fleet-manager on %s (assuming %s, %s)\n' \
			"$HUB_CTX" "$aud" "$root" >&2
	else
		aud="$(fm_deploy_env FLEET_AUDIENCE)"
		root="$(fm_deploy_env OPERATOR_TRUST_ROOT_ID)"
		[ -n "$aud" ] && [ -n "$root" ] || {
			fail "9 resume" "deploy/fleet-manager on $HUB_CTX sets no FLEET_AUDIENCE or OPERATOR_TRUST_ROOT_ID"
			return 1
		}
	fi
	# Mint for the registry pod name exactly as the hub lists it, in the
	# remote namespace, for the hub's own audience and trust root.
	run_or_echo "resume-token mint" -- resume_token mint \
		--agent "$TARGET" --namespace "$AGENTS_NS" \
		--audience "$aud" --trust-root "$root" \
		--approval remote-tenant-lab --lifetime 10m --required-signatures 2 \
		--out "$RESUME_TOKEN_FILE" || {
		fail "9 resume" "resume-token mint failed for $TARGET"
		return 1
	}
	# Both operators sign. The private key is a FILE PATH argument.
	for n in "${LAB_OPERATORS[@]}"; do
		run_or_echo "resume-token sign $n" -- resume_token sign \
			--token "$RESUME_TOKEN_FILE" --operator "${OPERATOR_PREFIX}${n}" \
			--key "$OPKEYS_DIR/$n.key" || {
			fail "9 resume" "resume-token sign failed for operator $n"
			return 1
		}
	done
	run_or_echo "resume-token request" -- resume_token request \
		--token "$RESUME_TOKEN_FILE" --out "$RESUME_REQUEST_FILE" || {
		fail "9 resume" "resume-token request failed"
		return 1
	}
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN POST /api/v1/fleet/resume/%s with the signed request body, expect 202 resume_requested\n' "$TARGET" >&2
		pass "9 resume" "POST /api/v1/fleet/resume/$TARGET, token signed by ${LAB_OPERATORS[*]} (dry run)"
		return 0
	fi
	local code body="$TRANSFER_DIR/resume-response.json"
	code="$(fm_file POST "/api/v1/fleet/resume/$TARGET" "$RESUME_REQUEST_FILE" "$body")"
	# A registry hit answers 202 with a record whose state is resume_requested.
	if [ "$code" = "202" ] && grep -qF 'resume_requested' <"$body"; then
		pass "9 resume" "$TARGET accepted, 202, record state resume_requested"
	else
		fail "9 resume" "expected 202 resume_requested for $TARGET, got $code: $(head -c 160 "$body")"
	fi
}

# step_9b: the replay ledger. The token step 9 consumed, posted again under a
# DIFFERENT idempotency key, must be refused with 409 (the same key would be
# an idempotent retry and is not a replay).
step_9b_replay() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'DRY-RUN POST /api/v1/fleet/resume/%s again with the same token and a new idempotency_key, expect 409\n' "$TARGET" >&2
		pass "9b replay" "same token, new idempotency key, 409 (dry run)"
		return 0
	fi
	local replay="$TRANSFER_DIR/resume-replay.json" body="$TRANSFER_DIR/resume-replay-response.json" code
	[ -s "$RESUME_REQUEST_FILE" ] || {
		fail "9b replay" "no request body from step 9 to replay"
		return 1
	}
	sed -E 's/"idempotency_key"[[:space:]]*:[[:space:]]*"[^"]*"/"idempotency_key": "remote-tenant-lab-replay-'"$(date +%s)"'"/' \
		"$RESUME_REQUEST_FILE" >"$replay" || {
		fail "9b replay" "could not write $replay"
		return 1
	}
	grep -qF 'remote-tenant-lab-replay-' <"$replay" || {
		fail "9b replay" "the request body carries no idempotency_key to change"
		return 1
	}
	code="$(fm_file POST "/api/v1/fleet/resume/$TARGET" "$replay" "$body")"
	if [ "$code" = "409" ]; then
		pass "9b replay" "consumed token under a new idempotency key refused, 409"
	else
		fail "9b replay" "expected 409 for the replayed token, got $code: $(head -c 160 "$body")"
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
		--load-kind-image) LOAD_KIND_IMAGE=1; shift ;;
		-h | --help) usage; return 0 ;;
		*) usage >&2; die "unknown argument: $1" 2 ;;
		esac
	done
	for v in "$HUB_CTX" "$REMOTE_CTX" "$CLUSTER_ID" "$TIMEOUT"; do
		[ -n "$v" ] || die "an option was given an empty value" 2
	done
	case "$TIMEOUT" in '' | *[!0-9]*) die "--timeout must be a whole number of seconds" 2 ;; esac
	[ "$HUB_CTX" != "$REMOTE_CTX" ] || die "--hub-context and --remote-context must differ" 2
	if [ -z "$HUB_GATEWAY_NODEPORT" ] && [ "$DRY_RUN" -eq 0 ]; then
		HUB_GATEWAY_NODEPORT="$(hub -n ingress get svc -l gateway.envoyproxy.io/owning-gateway-name=cluster \
			-o jsonpath='{.items[0].spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"
	fi
	# A dry run reads nothing from either cluster, so it takes the lab default.
	[ -n "$HUB_GATEWAY_NODEPORT" ] || HUB_GATEWAY_NODEPORT=30476
	HUB_URL="${HUB_URL:-https://${HUB_GATEWAY_HOST}:${HUB_GATEWAY_NODEPORT}}"

	trap cleanup EXIT
	log "hub $HUB_CTX, remote $REMOTE_CTX, warden posts to $HUB_URL, cluster id $CLUSTER_ID"
	[ "$DRY_RUN" -eq 1 ] && log "dry run: nothing is mutated"

	step_1_preflight
	# Steps 2 to 5 are prerequisites: running the contract steps after a failed
	# apply only produces a second, misleading failure.
	if [ "$FAILED" -eq 0 ]; then step_2_mint_and_emit; fi
	if [ "$FAILED" -eq 0 ]; then step_3_apply_secrets; fi
	if [ "$FAILED" -eq 0 ]; then step_3b_attached_preflight; fi
	if [ "$FAILED" -eq 0 ]; then step_4_dns; fi
	if [ "$FAILED" -eq 0 ]; then step_5_overlay; fi
	if [ "$FAILED" -eq 0 ]; then step_5b_target; fi
	if [ "$FAILED" -eq 0 ]; then
		start_port_forward
		step_6_report
		step_7_stun
		step_8_stun_ack
		step_9_resume
		step_9b_replay
		step_10_resume_ack
	fi

	print_table
	[ "$FAILED" -eq 0 ] || return 1
	return 0
}

main "$@"
