#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/lib/dual-cluster.sh : shared contract for the SLDC dual Kind topology
#
# Sourced by scripts/dual-cluster-up.sh, scripts/dual-cluster-down.sh and
# test/dual-cluster-networking.bats. Holds the topology constants (every one
# overridable from the environment), the context nicknames, and the pure
# functions (Corefile splice and stub-block lint) that the hermetic tests
# exercise directly.
#
# Context nicknames for interactive shells:
#   source scripts/lib/dual-cluster.sh
#   kosr get pods -A      # kubectl --context kind-osramp
#   khub get pods -A      # kubectl --context kind-signalloom-hub

# Injectable binaries (tier-1 tests replace every one of them).
DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CILIUM_BIN="${CILIUM_BIN:-cilium}"

# Topology contract (Proposal Appendix B).
SLDC_BRIDGE_NAME="${SLDC_BRIDGE_NAME:-signalloom-bridge}"
SLDC_BRIDGE_CIDR="${SLDC_BRIDGE_CIDR:-172.19.0.0/16}"
SLDC_BRIDGE_GATEWAY="${SLDC_BRIDGE_GATEWAY:-172.19.0.1}"
SLDC_OSRAMP_CLUSTER="${SLDC_OSRAMP_CLUSTER:-osramp}"
SLDC_HUB_CLUSTER="${SLDC_HUB_CLUSTER:-signalloom-hub}"
SLDC_OSRAMP_IP="${SLDC_OSRAMP_IP:-172.19.0.10}"
SLDC_HUB_IP="${SLDC_HUB_IP:-172.19.0.20}"
SLDC_OSRAMP_CTX="${SLDC_OSRAMP_CTX:-kind-${SLDC_OSRAMP_CLUSTER}}"
SLDC_HUB_CTX="${SLDC_HUB_CTX:-kind-${SLDC_HUB_CLUSTER}}"
SLDC_OSRAMP_ZONE="${SLDC_OSRAMP_ZONE:-osramp.local}"
SLDC_HUB_ZONE="${SLDC_HUB_ZONE:-signalloom.hub}"
SLDC_BRIDGE_DNS_PORT="${SLDC_BRIDGE_DNS_PORT:-53}"
SLDC_CILIUM_VERSION="${SLDC_CILIUM_VERSION:-1.16.7}"

SLDC_MARK_BEGIN="# BEGIN sldc-cross-cluster (managed by scripts/dual-cluster-up.sh; do not edit)"
SLDC_MARK_END="# END sldc-cross-cluster"

kosr() { "$KUBECTL_BIN" --context "$SLDC_OSRAMP_CTX" "$@"; }
khub() { "$KUBECTL_BIN" --context "$SLDC_HUB_CTX" "$@"; }

sldc_log() { printf '==> %s\n' "$*" >&2; }
sldc_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Fail before any action when a required binary is absent. Without this a
# missing kind reads as "cluster absent" (down reports a clean teardown, up
# retries kind create) and a missing docker exits 127 with no message.
sldc_require_tools() {
  local t
  for t in "$@"; do
    command -v -- "$t" >/dev/null 2>&1 || sldc_die "missing required tool: $t"
  done
}

# Kind names its single node "<cluster>-control-plane".
sldc_node() { printf '%s-control-plane\n' "$1"; }

sldc_cluster_exists() {
  "$KIND_BIN" get clusters 2>/dev/null | grep -qx -- "$1"
}

# IPv4 address of container $1 on network $2 (empty when not attached).
sldc_container_ip() {
  "$DOCKER_BIN" inspect "$1" \
    --format "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" 2>/dev/null
}

# Remove any previous managed block from a Corefile on stdin, then append
# the block in $1 wrapped in markers. Idempotent: splice(splice(x)) == splice(x).
sldc_splice_corefile() {
  local block="$1"
  awk -v b="$SLDC_MARK_BEGIN" -v e="$SLDC_MARK_END" '
    index($0, "# BEGIN sldc-cross-cluster") == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }'
  printf '%s\n%s\n%s\n' "$SLDC_MARK_BEGIN" "${block%$'\n'}" "$SLDC_MARK_END"
}

# Strip the managed block (teardown). Output is the Corefile without it.
sldc_strip_corefile() {
  awk -v e="$SLDC_MARK_END" '
    index($0, "# BEGIN sldc-cross-cluster") == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }'
}

# Lint a stub block against the loop-safety rules. Prints each violation and
# returns non-zero when any are present:
#   * every server block is exactly one of the two SLDC zones, on :53
#   * no `fallthrough` anywhere
#   * a zone forwards `.` only to the bridge DNS responder of the cluster that
#     OWNS the zone (hub zone -> hub IP, workload zone -> workload IP). A
#     forward to the local node's own IP would loop straight back.
#   * a zone is either forwarded or answered by template, never both
sldc_lint_stub_block() {
  local block="$1" bad=0 zone="" line want
  local -A fwd=() tmpl=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^([^[:space:]]+):([0-9]+)[[:space:]]*\{$ ]]; then
      zone="${BASH_REMATCH[1]}"
      if [[ "${BASH_REMATCH[2]}" != 53 || ( "$zone" != "$SLDC_HUB_ZONE" && "$zone" != "$SLDC_OSRAMP_ZONE" ) ]]; then
        echo "lint: server block '$zone:${BASH_REMATCH[2]}' is not one of $SLDC_HUB_ZONE:53, $SLDC_OSRAMP_ZONE:53"
        bad=1
      fi
    elif [[ "$line" =~ ^forward[[:space:]] ]]; then
      if [[ ! "$line" =~ ^forward[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]{]+) ]]; then
        echo "lint: unparsable forward '$line'"; bad=1; continue
      fi
      [[ "$zone" == "$SLDC_HUB_ZONE" ]] && want="$SLDC_HUB_IP:$SLDC_BRIDGE_DNS_PORT" || want="$SLDC_OSRAMP_IP:$SLDC_BRIDGE_DNS_PORT"
      if [[ "${BASH_REMATCH[1]}" != "." ]]; then
        echo "lint: forward in zone '$zone' must forward '.', got '${BASH_REMATCH[1]}'"; bad=1
      fi
      if [[ "${BASH_REMATCH[2]}" != "$want" ]]; then
        echo "lint: zone '$zone' forwards to '${BASH_REMATCH[2]}', expected its owner '$want'"; bad=1
      fi
      fwd[$zone]=1
    elif [[ "$line" =~ ^template[[:space:]] ]]; then
      tmpl[$zone]=1
    elif [[ "$line" =~ ^fallthrough ]]; then
      echo "lint: 'fallthrough' in zone '$zone' can bounce queries between clusters"; bad=1
    fi
  done <<<"$block"
  for zone in "${!fwd[@]}"; do
    if [[ -n "${tmpl[$zone]:-}" ]]; then
      echo "lint: zone '$zone' is both forwarded and templated"; bad=1
    fi
  done
  return "$bad"
}
