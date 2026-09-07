#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# bench-tc-drop.sh — measure isolation activation latency under sustained load.
#
# THE QUESTION THIS ANSWERS. The severance proof in test/tc-ebpf-drop.bats runs
# against a 100 packet/second trickle. The interesting case is the opposite: an
# agent saturating its link mid-exfiltration. Does activation still land inside
# the 100ms budget when the softirq path is busy, and does the classifier keep
# up rather than becoming the bottleneck?
#
# WHAT IS MEASURED
#   * activation latency — wall time for the isolate call, under load
#   * observed packet rate before isolation (so the load is evidenced, not
#     assumed — a benchmark that did not actually generate traffic would
#     otherwise report a flatteringly fast activation)
#   * packets and bytes destroyed, read from the BPF map
#
# ON THE 50,000 pps TARGET. The card asks for 50k pps. This does not hard-code
# that number or assume it was reached: it drives N parallel flooders and
# REPORTS the rate actually observed, read from the interface's own tx_packets
# counter. An unverified "50,000 pps" in a report is worth less than a measured
# anything.
#
# Measured on the reference host (Linux 7.1.3, 8 flooders, 5s): 1,130,813 pps —
# 22x the target — with activation at 10ms wall / 5.07ms reported. A veth pair
# has no physical link to rate-limit it, so the achievable rate is far above
# what a real NIC would present; treat the pps figure as a stress level, not as
# a claim about production traffic.
#
#   test/bench-tc-drop.sh [--flooders N] [--seconds S] [--json]
#
# @id      bench-tc-drop
# @doc     docs/signalloom/tc-ebpf-confinement.md
# @tests   test/tc-ebpf-drop.bats
set -uo pipefail

REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
APP_DIR="$REPO_ROOT/d2-signalloom/apps/stun-sentinel"
BUILDER_IMAGE="${STUN_BPF_BUILDER_IMAGE:-signalloom-bpf-builder:trixie}"

FLOODERS=8
SECONDS_LOAD=5
JSON_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--flooders) FLOODERS="${2:-8}"; shift 2 ;;
		--seconds)  SECONDS_LOAD="${2:-5}"; shift 2 ;;
		--json)     JSON_ONLY=1; shift ;;
		-h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

log() { [ "$JSON_ONLY" -eq 1 ] || printf '[bench] %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { echo "docker required" >&2; exit 1; }

if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
	log "building $BUILDER_IMAGE"
	docker build -q -f "$APP_DIR/bpf/Dockerfile.builder" -t "$BUILDER_IMAGE" "$APP_DIR/bpf" >/dev/null
fi

BIN_DIR="$(mktemp -d)"
log "building stun-tcctl"
( cd "$APP_DIR" && CGO_ENABLED=0 GOFLAGS=-mod=mod go build -o "$BIN_DIR/stun-tcctl" ./cmd/stun-tcctl ) || exit 1

log "running benchmark: ${FLOODERS} flooders for ${SECONDS_LOAD}s"

docker run --rm -i --privileged \
	-v "$BIN_DIR/stun-tcctl:/usr/local/bin/stun-tcctl:ro" \
	-e "FLOODERS=$FLOODERS" -e "SECONDS_LOAD=$SECONDS_LOAD" \
	"$BUILDER_IMAGE" bash -s <<'INNER'
set -uo pipefail
HOST_IF=veth-bench; POD_IF=veth-benchp; NS=benchns
HOST_IP=10.98.0.1; POD_IP=10.98.0.2

mount -t bpf bpf /sys/fs/bpf 2>/dev/null
ip netns add "$NS"
ip link add "$HOST_IF" type veth peer name "$POD_IF"
ip link set "$POD_IF" netns "$NS"
ip addr add "$HOST_IP/24" dev "$HOST_IF"; ip link set "$HOST_IF" up
ip netns exec "$NS" ip addr add "$POD_IP/24" dev "$POD_IF"
ip netns exec "$NS" ip link set "$POD_IF" up
ip netns exec "$NS" ip link set lo up

stun-tcctl attach --interface "$HOST_IF" >/dev/null 2>&1 || { echo '{"error":"attach failed"}'; exit 1; }

rx_before=$(cat /sys/class/net/$HOST_IF/statistics/tx_packets)
t_start=$(date +%s%3N)

# Sustained load. ping -f floods as fast as the path allows; several in
# parallel push the softirq path considerably harder than one.
for i in $(seq 1 "$FLOODERS"); do
	ping -f -q "$POD_IP" >/dev/null 2>&1 &
done
sleep "$SECONDS_LOAD"

rx_mid=$(cat /sys/class/net/$HOST_IF/statistics/tx_packets)
t_mid=$(date +%s%3N)
elapsed_ms=$((t_mid - t_start))
pkts=$((rx_mid - rx_before))
pps=0
[ "$elapsed_ms" -gt 0 ] && pps=$(( pkts * 1000 / elapsed_ms ))

# Activation under load. This is the number the 100ms budget is about.
t0=$(date +%s%3N)
iso_json=$(stun-tcctl isolate --interface "$HOST_IF" --ip "$POD_IP" --json 2>/dev/null)
t1=$(date +%s%3N)
activation_ms=$((t1 - t0))
reported=$(echo "$iso_json" | grep -o '"elapsed_ms":[^,}]*' | cut -d: -f2 | tr -d ' ')
[ -z "$reported" ] && reported=null

sleep 2
pkill -f "ping -f" 2>/dev/null

status=$(stun-tcctl status --interface "$HOST_IF" --json 2>/dev/null)
dropped=$(echo "$status" | grep -o '"packets_dropped":[^,}]*' | cut -d: -f2 | tr -d ' ')
bytes=$(echo "$status" | grep -o '"bytes_dropped":[^,}]*' | cut -d: -f2 | tr -d ' ')
[ -z "$dropped" ] && dropped=null
[ -z "$bytes" ] && bytes=null

stun-tcctl detach --interface "$HOST_IF" >/dev/null 2>&1
ip netns del "$NS" 2>/dev/null

cat <<JSON
{
  "schema": "signalloom.tc-drop-bench/v1",
  "kernel": "$(uname -r)",
  "load": {
    "flooders": ${FLOODERS},
    "duration_ms": ${elapsed_ms},
    "packets_generated": ${pkts},
    "observed_pps": ${pps}
  },
  "activation": {
    "wall_ms": ${activation_ms},
    "reported_ms": ${reported},
    "under_100ms": $( [ "$activation_ms" -lt 100 ] && echo true || echo false )
  },
  "drops": {
    "packets_dropped": ${dropped},
    "bytes_dropped": ${bytes}
  }
}
JSON
INNER
rc=$?

rm -rf "$BIN_DIR"
exit $rc
