#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test-tc-ebpf.sh — orchestrate the live eBPF TC severance experiment.
#
# Builds the CLI, then runs bpf/scenario.sh inside a privileged container with a
# real kernel, real veth pairs, a real verifier and a real conntrack table. The
# container is the correct environment rather than a workaround: this code ships
# as a node DaemonSet, and the build host has neither root (PR_SET_NO_NEW_PRIVS
# blocks sudo) nor an LLVM toolchain.
#
# Emits the measured evidence as JSON on stdout. Assertions live in
# test/tc-ebpf-drop.bats, which consumes this output.
#
#   scripts/test-tc-ebpf.sh                 # run, print JSON
#   scripts/test-tc-ebpf.sh --out FILE      # also write JSON to FILE
#
# @id      test-tc-ebpf
# @doc     docs/signalloom/tc-ebpf-confinement.md
# @tests   test/tc-ebpf-drop.bats
set -uo pipefail

REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
APP_DIR="$REPO_ROOT/d2-signalloom/apps/stun-sentinel"
BUILDER_IMAGE="${STUN_BPF_BUILDER_IMAGE:-signalloom-bpf-builder:trixie}"

OUT_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT_FILE="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

log() { printf '[tc-ebpf] %s\n' "$*" >&2; }

require() {
	command -v "$1" >/dev/null 2>&1 || {
		log "FATAL: $1 is required but not installed"
		exit 1
	}
}

require docker
require go

# The builder image carries BOTH the compile toolchain and the kernel tooling
# the scenario needs (iproute2, conntrack, bpftool, netcat, iptables).
if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
	log "building $BUILDER_IMAGE"
	docker build -q -f "$APP_DIR/bpf/Dockerfile.builder" -t "$BUILDER_IMAGE" "$APP_DIR/bpf" >/dev/null || {
		log "FATAL: builder image build failed"
		exit 1
	}
fi

BIN="$(mktemp -d)/stun-tcctl"
log "building stun-tcctl"
( cd "$APP_DIR" && CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/gopath}" GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GOFLAGS=-mod=mod go build -o "$BIN" ./cmd/stun-tcctl ) || {
	log "FATAL: go build failed"
	exit 1
}

log "running live scenario in a privileged container"
docker run --rm --privileged \
	-v "$BIN:/usr/local/bin/stun-tcctl:ro" \
	-v "$APP_DIR/bpf/scenario.sh:/scenario.sh:ro" \
	"$BUILDER_IMAGE" \
	bash /scenario.sh > "${OUT_FILE:-/dev/stdout}"
rc=$?

if [ -n "$OUT_FILE" ]; then
	cat "$OUT_FILE"
fi

rm -rf "$(dirname "$BIN")"
exit "$rc"
