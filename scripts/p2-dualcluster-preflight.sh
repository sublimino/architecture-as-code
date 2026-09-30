#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/p2-dualcluster-preflight.sh :  SLDC Phase 2 dual-cluster pre-flight audit
#
# Read-only verification that the host can carry the Appendix B dual Kind
# topology (kind-osramp + kind-signalloom-hub on signalloom-bridge
# 172.19.0.0/16) before SLDC-P2-1 provisions anything:
#
#   1. Docker bridge subnet: signalloom-bridge either exists with the expected
#      CIDR/gateway, or the CIDR is unclaimed by every other docker network and
#      by every non-docker host route (VPN, Tailscale, WireGuard).
#   2. Reserved node IPs (172.19.0.10 / .20) are not held by a container.
#   3. Host ports 34777 / 34788 / 31443 / 30080 are free (owner named if not);
#      443 / 8080 / 8082 / 8200 are reported as advisory (in-cluster ports).
#   4. Existing Kind clusters that would collide with the Appendix B names.
#   5. Cluster manifests infra/kind/cluster-{osramp,signalloom-hub}.yaml.
#   6. SPIRE trust domains in d2-agent-trust/ and d2-signalloom/infra/.
#   7. CoreDNS stub-zone requirement on the live workload cluster.
#   8. OpenBao JWT bootstrap: glob claims, trust domain in bound sub, JWKS
#      reachability model, transit engine presence.
#   9. Host resources: RAM >= 8 GiB (hard blocker), inotify limits, sudo.
#  10. Optional (--l3-probe): disposable user-defined bridge on a free subnet
#      with two containers pinned to .10/.20, bidirectional ping, torn down.
#
# Nothing here creates, deletes or edits a cluster, network or host setting,
# except the --l3-probe network/containers, which are removed on exit.
#
# Every external binary is injectable for tier-1 tests:
#   DOCKER_BIN KIND_BIN KUBECTL_BIN SS_BIN IP_BIN SUDO_BIN
#   REPO_ROOT AUDIT_JSON MEMINFO_FILE INOTIFY_WATCHES_FILE INOTIFY_INSTANCES_FILE
#
# Exit codes: 0 no blockers, 1 at least one blocker, 2 usage / docker unusable.
#
# Doc:   docs/eap/SLDC-P2-TOPOLOGY-AUDIT.md
# Tests: test/p2-dualcluster-preflight.bats

set -o pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AUDIT_JSON="${AUDIT_JSON:-${REPO_ROOT}/ci-evidence/p2-preflight-audit.json}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
SS_BIN="${SS_BIN:-ss}"
IP_BIN="${IP_BIN:-ip}"
SUDO_BIN="${SUDO_BIN:-sudo}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
INOTIFY_WATCHES_FILE="${INOTIFY_WATCHES_FILE:-/proc/sys/fs/inotify/max_user_watches}"
INOTIFY_INSTANCES_FILE="${INOTIFY_INSTANCES_FILE:-/proc/sys/fs/inotify/max_user_instances}"

P2_BRIDGE_NAME="${P2_BRIDGE_NAME:-signalloom-bridge}"
P2_BRIDGE_CIDR="${P2_BRIDGE_CIDR:-172.19.0.0/16}"
P2_BRIDGE_GATEWAY="${P2_BRIDGE_GATEWAY:-172.19.0.1}"
P2_NODE_IPS="${P2_NODE_IPS:-172.19.0.10 172.19.0.20}"
P2_HOST_PORTS="${P2_HOST_PORTS:-34777 34788 31443 30080}"
P2_ADVISORY_PORTS="${P2_ADVISORY_PORTS:-443 8080 8082 8200}"
P2_WORKLOAD_CLUSTER="${P2_WORKLOAD_CLUSTER:-osramp}"
P2_HUB_CLUSTER="${P2_HUB_CLUSTER:-signalloom-hub}"
P2_WORKLOAD_TD="${P2_WORKLOAD_TD:-osramp.local}"
P2_HUB_TD="${P2_HUB_TD:-signalloom.hub}"
P2_MIN_RAM_KB="${P2_MIN_RAM_KB:-8388608}"
P2_MIN_WATCHES="${P2_MIN_WATCHES:-524288}"
P2_MIN_INSTANCES="${P2_MIN_INSTANCES:-8192}"
P2_PROBE_IMAGE="${P2_PROBE_IMAGE:-alpine:3.20}"

L3_PROBE=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: scripts/p2-dualcluster-preflight.sh [--l3-probe] [--quiet] [--help]

Read-only SLDC Phase 2 dual-cluster pre-flight. Writes ci-evidence/p2-preflight-audit.json
(override with AUDIT_JSON=path). Exit 0 = no blockers, 1 = blockers found, 2 = usage/docker error.

  --l3-probe  also create a disposable bridge on a free 172.x/16 with two containers at
              .10/.20, ping both ways, verify static IPs, then remove everything
  --quiet     print only the summary lines
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --l3-probe) L3_PROBE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "p2-preflight: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

CHECKS_FILE="$(mktemp)"
PROBE_NET=""
PROBE_CONTAINERS=()
cleanup() {
  local c
  for c in "${PROBE_CONTAINERS[@]}"; do
    "$DOCKER_BIN" rm -f "$c" >/dev/null 2>&1 || true
  done
  if [[ -n "$PROBE_NET" ]]; then
    "$DOCKER_BIN" network rm "$PROBE_NET" >/dev/null 2>&1 || true
  fi
  rm -f "$CHECKS_FILE"
}
trap cleanup EXIT

BLOCKERS=0; DRIFT=0; ADVISORY=0; PASSED=0

# record ID SEVERITY(pass|blocker|drift|advisory) SUMMARY [EVIDENCE]
record() {
  local id="$1" sev="$2" summary="$3" evidence="${4:-}"
  case "$sev" in
    pass) PASSED=$((PASSED + 1)) ;;
    blocker) BLOCKERS=$((BLOCKERS + 1)) ;;
    drift) DRIFT=$((DRIFT + 1)) ;;
    advisory) ADVISORY=$((ADVISORY + 1)) ;;
  esac
  [[ "$QUIET" == 1 ]] || printf '[%-8s] %-28s %s\n' "$sev" "$id" "$summary"
  jq -cn --arg id "$id" --arg severity "$sev" --arg summary "$summary" --arg evidence "$evidence" \
    '{id:$id, severity:$severity, summary:$summary, evidence:$evidence}' >>"$CHECKS_FILE"
}

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# cidr_overlap A B :  true when the two IPv4 CIDRs share any address.
cidr_overlap() {
  local n1="${1%/*}" p1="${1#*/}" n2="${2%/*}" p2="${2#*/}"
  [[ "$1" == */* ]] || p1=32
  [[ "$2" == */* ]] || p2=32
  local p=$(( p1 < p2 ? p1 : p2 ))
  local mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  [[ $(( $(ip2int "$n1") & mask )) -eq $(( $(ip2int "$n2") & mask )) ]]
}

# --- 0. Docker reachable -------------------------------------------------
if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  echo "p2-preflight: docker daemon unreachable via ${DOCKER_BIN}" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "p2-preflight: jq required" >&2; exit 2; }

# --- 1. Docker bridge subnet --------------------------------------------
declare -A NET_SUBNETS=()
while IFS= read -r net; do
  [[ -n "$net" ]] || continue
  NET_SUBNETS["$net"]="$("$DOCKER_BIN" network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}|{{.Gateway}} {{end}}' 2>/dev/null | xargs)"
done < <("$DOCKER_BIN" network ls --format '{{.Name}}' 2>/dev/null)

BRIDGE_STATE="absent"
if [[ -n "${NET_SUBNETS[$P2_BRIDGE_NAME]+x}" ]]; then
  BRIDGE_STATE="present"
  entry="${NET_SUBNETS[$P2_BRIDGE_NAME]}"
  subnet="${entry%%|*}"; gw="${entry#*|}"; gw="${gw%% *}"
  if [[ "$subnet" == "$P2_BRIDGE_CIDR" && "$gw" == "$P2_BRIDGE_GATEWAY" ]]; then
    record bridge.cidr pass "${P2_BRIDGE_NAME} exists with ${subnet} gw ${gw}" "$entry"
  else
    record bridge.cidr blocker "${P2_BRIDGE_NAME} exists but is ${subnet} gw ${gw}; expected ${P2_BRIDGE_CIDR} gw ${P2_BRIDGE_GATEWAY}" "$entry"
  fi
else
  record bridge.exists advisory "${P2_BRIDGE_NAME} not yet created (P2-1 creates it)" ""
fi

conflicts=()
for net in "${!NET_SUBNETS[@]}"; do
  [[ "$net" == "$P2_BRIDGE_NAME" ]] && continue
  for pair in ${NET_SUBNETS[$net]}; do
    s="${pair%%|*}"
    [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || continue
    if cidr_overlap "$s" "$P2_BRIDGE_CIDR"; then
      n_containers="$("$DOCKER_BIN" network inspect "$net" --format '{{len .Containers}}' 2>/dev/null)"
      conflicts+=("${net}=${s} (containers=${n_containers:-?})")
    fi
  done
done
if [[ ${#conflicts[@]} -eq 0 ]]; then
  record bridge.overlap.docker pass "no other docker network overlaps ${P2_BRIDGE_CIDR}" ""
else
  record bridge.overlap.docker blocker "${P2_BRIDGE_CIDR} already allocated to: ${conflicts[*]}" "${conflicts[*]}"
fi

route_conflicts=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  dst="${line%% *}"
  [[ "$dst" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || continue
  dev="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$line")"
  # Docker-owned bridges are judged by the network check above.
  [[ "$dev" =~ ^(br-|docker0|veth) ]] && continue
  if cidr_overlap "$dst" "$P2_BRIDGE_CIDR"; then
    route_conflicts+=("${dst} dev ${dev}")
  fi
done < <("$IP_BIN" -4 route show table all 2>/dev/null | grep -Ev '^(local|broadcast|multicast|unreachable) ')
if [[ ${#route_conflicts[@]} -eq 0 ]]; then
  record bridge.overlap.routes pass "no VPN/host route overlaps ${P2_BRIDGE_CIDR}" ""
else
  record bridge.overlap.routes blocker "host routes overlap ${P2_BRIDGE_CIDR}: ${route_conflicts[*]}" "${route_conflicts[*]}"
fi

# --- 2. Reserved node IPs -------------------------------------------------
held=()
for net in "${!NET_SUBNETS[@]}"; do
  members="$("$DOCKER_BIN" network inspect "$net" --format '{{range .Containers}}{{.Name}}={{.IPv4Address}} {{end}}' 2>/dev/null)"
  for m in $members; do
    cip="${m#*=}"; cip="${cip%/*}"
    for want in $P2_NODE_IPS; do
      [[ "$cip" == "$want" ]] && held+=("${want} held by ${m%%=*} on ${net}")
    done
  done
done
if [[ ${#held[@]} -eq 0 ]]; then
  record node.ips pass "reserved node IPs ${P2_NODE_IPS// /, } unheld" ""
else
  record node.ips blocker "reserved node IPs in use: ${held[*]}" "${held[*]}"
fi

# --- 3. Host ports --------------------------------------------------------
LISTEN="$("$SS_BIN" -tlnH 2>/dev/null | awk '{print $4}')"
DOCKER_PORTS="$("$DOCKER_BIN" ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null)"
# Docker publishes ranges as "0.0.0.0:8081-8082->8081-8082/tcp", so match the
# host side as a range, not a literal ":PORT->".
port_owner() {
  local p="$1" owners="" line name ports mapping host lo hi
  while IFS= read -r line; do
    name="${line%%|*}"; ports="${line#*|}"
    IFS=',' read -ra maps <<<"$ports"
    for mapping in "${maps[@]}"; do
      [[ "$mapping" == *"->"* ]] || continue
      host="${mapping%%->*}"; host="${host##*:}"
      lo="${host%-*}"; hi="${host#*-}"
      [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
      if (( p >= lo && p <= hi )); then owners+="${name} "; break; fi
    done
  done <<<"$DOCKER_PORTS"
  owners="$(tr ' ' '\n' <<<"$owners" | sort -u | xargs)"
  echo "${owners:-non-docker process}"
}
port_binds() { grep -E ":${1}\$" <<<"$LISTEN" | sort -u | xargs; }

for p in $P2_HOST_PORTS; do
  binds="$(port_binds "$p")"
  if [[ -z "$binds" ]]; then
    record "port.${p}" pass "host TCP ${p} free" ""
  else
    record "port.${p}" blocker "host TCP ${p} bound (${binds}) by $(port_owner "$p")" "$binds"
  fi
done
for p in $P2_ADVISORY_PORTS; do
  binds="$(port_binds "$p")"
  if [[ -n "$binds" ]]; then
    record "port.${p}.advisory" advisory "host TCP ${p} bound (${binds}) by $(port_owner "$p"); in-cluster only in Appendix B, blocks host port-forwards on this port" "$binds"
  fi
done

# --- 4. Existing Kind clusters ------------------------------------------
CLUSTERS="$("$KIND_BIN" get clusters 2>/dev/null)"
for c in "$P2_WORKLOAD_CLUSTER" "$P2_HUB_CLUSTER"; do
  if grep -qx "$c" <<<"$CLUSTERS"; then
    nets="$("$DOCKER_BIN" inspect "${c}-control-plane" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' 2>/dev/null | xargs)"
    if grep -q "${P2_BRIDGE_NAME}=" <<<"$nets"; then
      record "kind.${c}" pass "kind cluster ${c} already on ${P2_BRIDGE_NAME} (${nets})" "$nets"
    else
      record "kind.${c}" blocker "kind cluster ${c} already exists on ${nets:-unknown network}, not ${P2_BRIDGE_NAME}; P2-1 cannot create it without deleting or migrating it" "$nets"
    fi
  else
    record "kind.${c}" pass "no existing kind cluster named ${c}" ""
  fi
done

# --- 5. Cluster manifests -------------------------------------------------
check_manifest() {
  local file="$1" port="$2"
  local path="${REPO_ROOT}/${file}"
  if [[ ! -f "$path" ]]; then
    record "manifest.$(basename "$file" .yaml)" drift "${file} absent; P2-1 must author it from Appendix B.2" ""
    return
  fi
  local sum; sum="$(sha256sum "$path" | cut -d' ' -f1)"
  if grep -Eq "apiServerPort:[[:space:]]*${port}\b" "$path"; then
    record "manifest.$(basename "$file" .yaml)" pass "${file} present, apiServerPort ${port}" "sha256=${sum}"
  else
    record "manifest.$(basename "$file" .yaml)" drift "${file} present but apiServerPort is not ${port}" "sha256=${sum}"
  fi
}
check_manifest infra/kind/cluster-osramp.yaml 34777
check_manifest infra/kind/cluster-signalloom-hub.yaml 34788

# --- 6. SPIRE trust domains ----------------------------------------------
TD_SCAN_DIRS=()
for d in d2-agent-trust d2-signalloom/infra; do
  [[ -d "${REPO_ROOT}/${d}" ]] && TD_SCAN_DIRS+=("${REPO_ROOT}/${d}")
done
SERVER_TDS=""; ALL_TDS=""
if [[ ${#TD_SCAN_DIRS[@]} -gt 0 ]]; then
  SERVER_TDS="$(grep -rhoE --include='*.yaml' --include='*.yml' --include='*.conf' --include='*.hcl' \
    'server \{[^}]*trust_domain = "[^"]+"' "${TD_SCAN_DIRS[@]}" 2>/dev/null \
    | sed -E 's/.*trust_domain = "([^"]+)"/\1/' | sort -u | xargs)"
  ALL_TDS="$(grep -rhoE --include='*.yaml' --include='*.yml' --include='*.json' --include='*.conf' --include='*.hcl' \
    '(trust_domain = "[^"]+"|"?trustDomain"?:[[:space:]]*"?[a-z0-9.-]+)' "${TD_SCAN_DIRS[@]}" 2>/dev/null \
    | sed -E 's/.*(= "|:[[:space:]]*"?)([a-z0-9.-]+)"?$/\2/' | sort -u | xargs)"
fi
for pair in "workload:${P2_WORKLOAD_TD}" "hub:${P2_HUB_TD}"; do
  role="${pair%%:*}"; td="${pair#*:}"
  if grep -qw -- "$td" <<<"$SERVER_TDS"; then
    record "trustdomain.${role}" pass "SPIRE server trust_domain ${td} defined" "servers=${SERVER_TDS}"
  else
    record "trustdomain.${role}" drift "no SPIRE server declares trust_domain ${td}; servers declare [${SERVER_TDS:-none}], all references [${ALL_TDS:-none}]" "servers=${SERVER_TDS}; all=${ALL_TDS}"
  fi
done

# --- 7. CoreDNS stub-zone requirement ------------------------------------
corefile="$("$KUBECTL_BIN" --context "kind-${P2_WORKLOAD_CLUSTER}" -n kube-system get cm coredns \
  -o jsonpath='{.data.Corefile}' 2>/dev/null)"
if [[ -z "$corefile" ]]; then
  record coredns.stub advisory "kind-${P2_WORKLOAD_CLUSTER} Corefile unreadable; stub zone for ${P2_HUB_TD} requirement unverified" ""
elif grep -qE "^[[:space:]]*${P2_HUB_TD//./\\.}(:53)?[[:space:]]*\{" <<<"$corefile"; then
  record coredns.stub pass "kind-${P2_WORKLOAD_CLUSTER} Corefile already carries a ${P2_HUB_TD} stub zone" ""
else
  upstream="$(sed -nE 's/^[[:space:]]*forward \. ([^ {]+).*/\1/p' <<<"$corefile" | head -1)"
  record coredns.stub drift "kind-${P2_WORKLOAD_CLUSTER} Corefile has only '.:53' forwarding to ${upstream:-?}; a ${P2_HUB_TD} (or hub service) stub zone is required for cross-cluster names" "forward=${upstream}"
fi

# --- 8. OpenBao JWT bootstrap -------------------------------------------
BAO_DIR="${REPO_ROOT}/d2-signalloom/infra/inf-bao"
SUPERCRED="${BAO_DIR}/configs/base/openbao-supercred-bootstrap.yaml"
if [[ -f "$SUPERCRED" ]]; then
  if grep -Eq '"bound_claims_type":[[:space:]]*"glob"|bound_claims_type=glob' "$SUPERCRED"; then
    record openbao.glob pass "openbao-supercred-bootstrap.yaml sets bound_claims_type glob" ""
  else
    record openbao.glob drift "openbao-supercred-bootstrap.yaml lacks bound_claims_type glob" ""
  fi
  subs="$(grep -oE 'spiffe://[a-z0-9.-]+' "$SUPERCRED" | sed 's#spiffe://##' | sort -u | xargs)"
  if grep -qw -- "$P2_WORKLOAD_TD" <<<"$subs"; then
    record openbao.sub_td pass "bound sub uses ${P2_WORKLOAD_TD}" "$subs"
  else
    record openbao.sub_td drift "bound sub trust domain is [${subs:-none}], not ${P2_WORKLOAD_TD}; cross-cluster tokens will not match" "$subs"
  fi
else
  record openbao.glob drift "openbao-supercred-bootstrap.yaml absent" ""
fi
jwks="$(grep -rhoE 'jwks_url="?[^" ]+' "$BAO_DIR" 2>/dev/null | sed -E 's/jwks_url="?//' | sort -u | xargs)"
if [[ -z "$jwks" ]]; then
  record openbao.jwks drift "no auth/jwt jwks_url configured under inf-bao" ""
elif grep -q 'svc.cluster.local' <<<"$jwks"; then
  record openbao.jwks drift "jwks_url is cluster-local (${jwks}); hub OpenBao cannot verify ${P2_WORKLOAD_TD} SVIDs without a federated bundle or cross-cluster JWKS endpoint" "$jwks"
else
  record openbao.jwks pass "jwks_url ${jwks}" "$jwks"
fi
if grep -rqE 'secrets enable.*transit|transit/keys' "$BAO_DIR" 2>/dev/null; then
  record openbao.transit pass "transit engine bootstrap present under inf-bao" ""
else
  record openbao.transit advisory "no transit engine bootstrap in inf-bao manifests; any transit mount is created outside the GitOps bootstrap" ""
fi

# --- 9. Host resources ----------------------------------------------------
mem_kb="$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null)"
if [[ -n "$mem_kb" && "$mem_kb" -ge "$P2_MIN_RAM_KB" ]]; then
  record host.ram pass "MemTotal $(( mem_kb / 1048576 )) GiB >= 8 GiB" "MemTotal=${mem_kb}kB"
else
  record host.ram blocker "MemTotal ${mem_kb:-unknown} kB < 8 GiB (hard blocker)" "MemTotal=${mem_kb}kB"
fi
watches="$(cat "$INOTIFY_WATCHES_FILE" 2>/dev/null)"; instances="$(cat "$INOTIFY_INSTANCES_FILE" 2>/dev/null)"
if [[ "${watches:-0}" -ge "$P2_MIN_WATCHES" && "${instances:-0}" -ge "$P2_MIN_INSTANCES" ]]; then
  record host.inotify pass "inotify watches=${watches} instances=${instances} meet ${P2_MIN_WATCHES}/${P2_MIN_INSTANCES}" ""
else
  if "$SUDO_BIN" -n true >/dev/null 2>&1; then
    record host.inotify drift "inotify watches=${watches} instances=${instances} below ${P2_MIN_WATCHES}/${P2_MIN_INSTANCES}; sudo available to raise" ""
  else
    record host.inotify blocker "inotify watches=${watches} instances=${instances} below minimum and sudo unavailable (hard blocker)" ""
  fi
fi
if "$SUDO_BIN" -n true >/dev/null 2>&1; then
  record host.sudo pass "non-interactive sudo available" ""
else
  record host.sudo advisory "non-interactive sudo unavailable in this context; docker-group access suffices for bridge management" ""
fi

# --- 10. Optional L3 reachability probe ----------------------------------
if [[ "$L3_PROBE" == 1 ]]; then
  probe_cidr=""
  for octet in 31 30 29 28 27 26 25; do
    cand="172.${octet}.0.0/16"; clash=0
    for net in "${!NET_SUBNETS[@]}"; do
      for pair in ${NET_SUBNETS[$net]}; do
        s="${pair%%|*}"
        [[ "$s" =~ ^[0-9]+\. ]] && cidr_overlap "$s" "$cand" && clash=1
      done
    done
    "$IP_BIN" -4 route show table all 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' | while read -r d; do
      cidr_overlap "$d" "$cand" && echo clash
    done | grep -q clash && clash=1
    [[ "$clash" == 0 ]] && { probe_cidr="$cand"; break; }
  done
  if [[ -z "$probe_cidr" ]]; then
    record l3.probe advisory "no free 172.25-31/16 subnet for the L3 probe" ""
  else
    base="${probe_cidr%.0.0/16}"
    PROBE_NET="sldc-p2-preflight-$$"
    if "$DOCKER_BIN" network create --driver bridge --subnet "$probe_cidr" --gateway "${base}.0.1" "$PROBE_NET" >/dev/null 2>&1; then
      ok=1; ev=""
      for suffix in 10 20; do
        name="${PROBE_NET}-n${suffix}"
        if "$DOCKER_BIN" run -d --rm --name "$name" --network "$PROBE_NET" --ip "${base}.0.${suffix}" \
             "$P2_PROBE_IMAGE" sleep 120 >/dev/null 2>&1; then
          PROBE_CONTAINERS+=("$name")
          got="$("$DOCKER_BIN" inspect "$name" --format "{{(index .NetworkSettings.Networks \"${PROBE_NET}\").IPAddress}}" 2>/dev/null)"
          ev+="${name}=${got} "
          [[ "$got" == "${base}.0.${suffix}" ]] || ok=0
        else
          ok=0; ev+="${name}=run-failed "
        fi
      done
      if [[ "$ok" == 1 ]] \
         && "$DOCKER_BIN" exec "${PROBE_NET}-n10" ping -c1 -W2 "${base}.0.20" >/dev/null 2>&1 \
         && "$DOCKER_BIN" exec "${PROBE_NET}-n20" ping -c1 -W2 "${base}.0.10" >/dev/null 2>&1; then
        record l3.probe pass "static IPs .10/.20 honoured and bidirectional ICMP on disposable ${probe_cidr}" "$ev"
      else
        record l3.probe blocker "static-IP or bidirectional reachability failed on disposable ${probe_cidr}" "$ev"
      fi
    else
      PROBE_NET=""
      record l3.probe blocker "could not create disposable bridge ${probe_cidr}" ""
    fi
  fi
fi

# --- Report ---------------------------------------------------------------
STATUS="pass"; [[ "$BLOCKERS" -gt 0 ]] && STATUS="fail"
mkdir -p "$(dirname "$AUDIT_JSON")"
jq -s \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg host "$(hostname)" \
  --arg status "$STATUS" \
  --arg bridge_name "$P2_BRIDGE_NAME" --arg bridge_cidr "$P2_BRIDGE_CIDR" \
  --arg bridge_gw "$P2_BRIDGE_GATEWAY" --arg bridge_state "$BRIDGE_STATE" \
  --arg node_ips "$P2_NODE_IPS" --arg host_ports "$P2_HOST_PORTS" \
  --arg workload_td "$P2_WORKLOAD_TD" --arg hub_td "$P2_HUB_TD" \
  --arg l3 "$L3_PROBE" \
  --argjson passed "$PASSED" --argjson blockers "$BLOCKERS" \
  --argjson drift "$DRIFT" --argjson advisory "$ADVISORY" \
  '{
     task: "SLDC-P2-PRE", timestamp: $ts, host: $host, status: $status,
     summary: {passed: $passed, blockers: $blockers, drift: $drift, advisory: $advisory},
     expected_topology: {
       bridge: {name: $bridge_name, cidr: $bridge_cidr, gateway: $bridge_gw, state: $bridge_state},
       node_ips: ($node_ips | split(" ")),
       host_ports: ($host_ports | split(" ") | map(tonumber)),
       trust_domains: {workload: $workload_td, hub: $hub_td}
     },
     l3_probe_requested: ($l3 == "1"),
     checks: .
   }' "$CHECKS_FILE" >"$AUDIT_JSON"

echo "P2 Preflight Summary: ${PASSED} passed, ${BLOCKERS} blockers, ${DRIFT} drift, ${ADVISORY} advisory"
echo "status=${STATUS} audit=${AUDIT_JSON}"
[[ "$STATUS" == "pass" ]]
