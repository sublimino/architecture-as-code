#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/p2-dualcluster-preflight.bats :  SLDC-P2-PRE dual-cluster pre-flight suite
#
# Target: scripts/p2-dualcluster-preflight.sh
# Doc:    docs/eap/SLDC-P2-TOPOLOGY-AUDIT.md
#
# Tier 1 (default, hermetic): every host binary (docker, kind, kubectl, ss, ip,
# sudo) and every /proc file is replaced by a fixture, so each gate is driven
# into pass and fail deterministically. Mutation tests copy the script, break one
# gate, and prove the corresponding failure fixture then goes green.
# Tier 2 (live): runs against the real host; skipped when docker is unreachable.
# The --l3-probe live test creates and removes a disposable network and only
# runs with P2_LIVE_L3=1.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/p2-dualcluster-preflight.sh"
  FAKE_DIR="${BATS_TEST_TMPDIR}/fake"
  FIX_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$FAKE_DIR/bin" "$FIX_REPO"
  write_fakes
  write_green_fixture
  export FAKE_DIR REPO_ROOT_FIX="$FIX_REPO"
  export DOCKER_BIN="$FAKE_DIR/bin/docker" KIND_BIN="$FAKE_DIR/bin/kind" \
    KUBECTL_BIN="$FAKE_DIR/bin/kubectl" SS_BIN="$FAKE_DIR/bin/ss" \
    IP_BIN="$FAKE_DIR/bin/ip" SUDO_BIN="$FAKE_DIR/bin/sudo" \
    MEMINFO_FILE="$FAKE_DIR/meminfo" INOTIFY_WATCHES_FILE="$FAKE_DIR/watches" \
    INOTIFY_INSTANCES_FILE="$FAKE_DIR/instances" \
    AUDIT_JSON="${BATS_TEST_TMPDIR}/audit.json"
}

run_fixture() { REPO_ROOT="$FIX_REPO" run bash "${1:-$SCRIPT}" "${@:2}"; }

check_sev() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .severity' "$AUDIT_JSON"; }

write_fakes() {
  # networks: name|subnet|gateway|member=ip/len,member=ip/len
  cat >"$FAKE_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ -n "$FAKE_DOCKER_DOWN" ]] && exit 1
case "$1" in
  info) exit 0 ;;
  ps) cat "$FAKE_DIR/ps" 2>/dev/null; exit 0 ;;
  inspect) f="$FAKE_DIR/inspect-$2"; [[ -f "$f" ]] && cat "$f" || exit 1; exit 0 ;;
  network)
    case "$2" in
      ls) cut -d'|' -f1 "$FAKE_DIR/networks"; exit 0 ;;
      inspect)
        line="$(grep "^$3|" "$FAKE_DIR/networks")" || exit 1
        IFS='|' read -r _ subnet gw members <<<"$line"
        case "$5" in
          *IPAM*) echo "${subnet}|${gw} " ;;
          *'len .Containers'*) if [[ -z "$members" ]]; then echo 0; else tr ',' '\n' <<<"$members" | wc -l; fi ;;
          *Containers*) tr ',' ' ' <<<"$members" ;;
        esac
        exit 0 ;;
    esac ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\ncat "$FAKE_DIR/clusters" 2>/dev/null\n' >"$FAKE_DIR/bin/kind"
  printf '#!/usr/bin/env bash\n[[ -f "$FAKE_DIR/corefile" ]] || exit 1\ncat "$FAKE_DIR/corefile"\n' >"$FAKE_DIR/bin/kubectl"
  printf '#!/usr/bin/env bash\ncat "$FAKE_DIR/ss" 2>/dev/null\n' >"$FAKE_DIR/bin/ss"
  printf '#!/usr/bin/env bash\ncat "$FAKE_DIR/routes" 2>/dev/null\n' >"$FAKE_DIR/bin/ip"
  printf '#!/usr/bin/env bash\nexit "${FAKE_SUDO_RC:-1}"\n' >"$FAKE_DIR/bin/sudo"
  chmod +x "$FAKE_DIR"/bin/*
}

write_green_fixture() {
  cat >"$FAKE_DIR/networks" <<'EOF'
bridge|172.17.0.0/16|172.17.0.1|
kind|172.18.0.0/16|172.18.0.1|registry-cache=172.18.0.2/16
archivista_default|172.24.0.0/16|172.24.0.1|archivista-1=172.24.0.2/16
EOF
  echo "archivista-1|0.0.0.0:8081-8082->8081-8082/tcp, [::]:8081-8082->8081-8082/tcp" >"$FAKE_DIR/ps"
  cat >"$FAKE_DIR/routes" <<'EOF'
default via 192.168.1.1 dev eno1 proto dhcp
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
172.18.0.0/16 dev br-f7f9142172f6 proto kernel scope link src 172.18.0.1
100.64.0.0/10 dev tailscale0 table 52
local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1
EOF
  cat >"$FAKE_DIR/ss" <<'EOF'
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:8082 0.0.0.0:*
EOF
  : >"$FAKE_DIR/clusters"
  cat >"$FAKE_DIR/corefile" <<'EOF'
.:53 {
    forward . /etc/resolv.conf
}
signalloom.hub:53 {
    forward . 172.19.0.20
}
EOF
  echo "MemTotal:       65011712 kB" >"$FAKE_DIR/meminfo"
  echo 1048576 >"$FAKE_DIR/watches"
  echo 10240 >"$FAKE_DIR/instances"

  mkdir -p "$FIX_REPO/infra/kind" "$FIX_REPO/d2-agent-trust" \
    "$FIX_REPO/d2-signalloom/infra/inf-bao/configs/base" \
    "$FIX_REPO/d2-signalloom/infra/spire-hub"
  printf 'kind: Cluster\nname: osramp\nnetworking:\n  apiServerPort: 34777\n' >"$FIX_REPO/infra/kind/cluster-osramp.yaml"
  printf 'kind: Cluster\nname: signalloom-hub\nnetworking:\n  apiServerPort: 34788\n' >"$FIX_REPO/infra/kind/cluster-signalloom-hub.yaml"
  cat >"$FIX_REPO/d2-agent-trust/spire-server.yaml" <<'EOF'
data:
  server.conf: |
    server { bind_port = "8081" trust_domain = "osramp.local" }
EOF
  cat >"$FIX_REPO/d2-signalloom/infra/spire-hub/spire-server.yaml" <<'EOF'
data:
  server.conf: |
    server { bind_port = "8081" trust_domain = "signalloom.hub" }
EOF
  cat >"$FIX_REPO/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml" <<'EOF'
              bao secrets enable transit || true
              bao write auth/jwt/config jwks_url="https://spire-bundle.signalloom.hub:8443/keys"
              {
                "bound_claims": {"sub": "spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault*"},
                "bound_claims_type": "glob"
              }
EOF
}

# --- Tier 1: hermetic ---------------------------------------------------

@test "P2PRE green fixture: no-argument invocation exits 0 with status=pass and zero blockers/drift" {
  run_fixture
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=pass" ]]
  jq -e '.status == "pass" and .summary.blockers == 0 and .summary.drift == 0' "$AUDIT_JSON"
  jq -e '.expected_topology.bridge.cidr == "172.19.0.0/16" and (.expected_topology.host_ports | index(34777) != null)' "$AUDIT_JSON"
}

@test "P2PRE bridge: a docker network holding 172.19.0.0/16 is a blocker naming the holder" {
  echo "clawdbot_default|172.19.0.0/16|172.19.0.1|" >>"$FAKE_DIR/networks"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev bridge.overlap.docker)" = "blocker" ]
  [[ "$output" =~ "clawdbot_default=172.19.0.0/16 (containers=0)" ]]
}

@test "P2PRE bridge: a partial overlap (172.19.128.0/17) is caught by CIDR arithmetic" {
  echo "partial|172.19.128.0/17|172.19.128.1|" >>"$FAKE_DIR/networks"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev bridge.overlap.docker)" = "blocker" ]
}

@test "P2PRE bridge: adjacent 172.18.0.0/16 and 172.20.0.0/16 are not false positives" {
  echo "neighbour|172.20.0.0/16|172.20.0.1|" >>"$FAKE_DIR/networks"
  run_fixture
  [ "$status" -eq 0 ]
  [ "$(check_sev bridge.overlap.docker)" = "pass" ]
}

@test "P2PRE bridge: existing signalloom-bridge with the wrong CIDR is a blocker" {
  echo "signalloom-bridge|172.30.0.0/16|172.30.0.1|" >>"$FAKE_DIR/networks"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev bridge.cidr)" = "blocker" ]
}

@test "P2PRE routes: a VPN route inside 172.19.0.0/16 is a blocker; docker bridge routes are ignored" {
  echo "172.19.5.0/24 dev tailscale0 table 52" >>"$FAKE_DIR/routes"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev bridge.overlap.routes)" = "blocker" ]
  [[ "$output" =~ "172.19.5.0/24 dev tailscale0" ]]
}

@test "P2PRE node IPs: a container already at 172.19.0.10 is a blocker" {
  echo "signalloom-bridge|172.19.0.0/16|172.19.0.1|squatter=172.19.0.10/16" >>"$FAKE_DIR/networks"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev node.ips)" = "blocker" ]
  [[ "$output" =~ "172.19.0.10 held by squatter" ]]
}

@test "P2PRE ports: a bound 34777 is a blocker and names the owning container" {
  echo "LISTEN 0 4096 127.0.0.1:34777 0.0.0.0:*" >>"$FAKE_DIR/ss"
  echo "osramp-control-plane|127.0.0.1:34777->6443/tcp" >>"$FAKE_DIR/ps"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev port.34777)" = "blocker" ]
  [[ "$output" =~ "by osramp-control-plane" ]]
}

@test "P2PRE ports: 34788, 31443 and 30080 are each gated independently" {
  for p in 34788 31443 30080; do
    write_green_fixture
    echo "LISTEN 0 4096 0.0.0.0:${p} 0.0.0.0:*" >>"$FAKE_DIR/ss"
    run_fixture
    [ "$status" -eq 1 ]
    [ "$(check_sev "port.${p}")" = "blocker" ]
  done
}

@test "P2PRE ports: a published port range attributes 8082 to its container as advisory only" {
  run_fixture
  [ "$status" -eq 0 ]
  [ "$(check_sev port.8082.advisory)" = "advisory" ]
  [[ "$output" =~ "by archivista-1" ]]
}

@test "P2PRE kind: an existing osramp cluster off signalloom-bridge is a blocker" {
  echo osramp >"$FAKE_DIR/clusters"
  echo "kind=172.18.0.5" >"$FAKE_DIR/inspect-osramp-control-plane"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev kind.osramp)" = "blocker" ]
}

@test "P2PRE manifests: absent infra/kind manifests are drift, not a blocker" {
  rm -f "$FIX_REPO"/infra/kind/*.yaml
  run_fixture
  [ "$status" -eq 0 ]
  [ "$(check_sev manifest.cluster-osramp)" = "drift" ]
  [ "$(check_sev manifest.cluster-signalloom-hub)" = "drift" ]
}

@test "P2PRE trust domains: servers declaring only signalloom.demo drift on both roles" {
  sed -i 's/osramp.local/signalloom.demo/; s/signalloom.hub/signalloom.demo/' \
    "$FIX_REPO/d2-agent-trust/spire-server.yaml" "$FIX_REPO/d2-signalloom/infra/spire-hub/spire-server.yaml"
  run_fixture
  [ "$(check_sev trustdomain.workload)" = "drift" ]
  [ "$(check_sev trustdomain.hub)" = "drift" ]
  [[ "$output" =~ "servers declare [signalloom.demo]" ]]
}

@test "P2PRE coredns: a Corefile without a hub stub zone is drift" {
  printf '.:53 {\n    forward . /etc/resolv.conf\n}\n' >"$FAKE_DIR/corefile"
  run_fixture
  [ "$(check_sev coredns.stub)" = "drift" ]
}

@test "P2PRE openbao: missing glob, wrong sub trust domain and cluster-local JWKS each drift" {
  cat >"$FIX_REPO/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml" <<'EOF'
              bao write auth/jwt/config jwks_url="http://spire-oidc.inf-bao.svc.cluster.local:8008/keys"
              {"bound_claims": {"sub": "spiffe://signalloom.demo/ns/x/sa/*cardvault*"}}
EOF
  run_fixture
  [ "$(check_sev openbao.glob)" = "drift" ]
  [ "$(check_sev openbao.sub_td)" = "drift" ]
  [ "$(check_sev openbao.jwks)" = "drift" ]
  [ "$(check_sev openbao.transit)" = "advisory" ]
}

@test "P2PRE host: MemTotal below 8 GiB is a hard blocker" {
  echo "MemTotal:        7000000 kB" >"$FAKE_DIR/meminfo"
  run_fixture
  [ "$status" -eq 1 ]
  [ "$(check_sev host.ram)" = "blocker" ]
}

@test "P2PRE host: low inotify is a blocker without sudo and drift with sudo" {
  echo 8192 >"$FAKE_DIR/watches"
  run_fixture
  [ "$(check_sev host.inotify)" = "blocker" ]
  FAKE_SUDO_RC=0 run_fixture
  [ "$(check_sev host.inotify)" = "drift" ]
}

@test "P2PRE usage: unreachable docker exits 2; unknown option exits 2" {
  FAKE_DOCKER_DOWN=1 run_fixture
  [ "$status" -eq 2 ]
  run_fixture "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "P2PRE mutation: breaking CIDR overlap lets the 172.19 collision through (test is not vacuous)" {
  mutant="${BATS_TEST_TMPDIR}/mutant-cidr.sh"
  sed 's/^  \[\[ \$(( \$(ip2int "\$n1") & mask )) -eq .*/  false/' "$SCRIPT" >"$mutant"
  ! cmp -s "$SCRIPT" "$mutant"
  echo "clawdbot_default|172.19.0.0/16|172.19.0.1|" >>"$FAKE_DIR/networks"
  run_fixture "$mutant"
  [ "$status" -eq 0 ]
  [ "$(check_sev bridge.overlap.docker)" = "pass" ]
}

@test "P2PRE mutation: blinding the socket scan lets a 34777 collision through (test is not vacuous)" {
  mutant="${BATS_TEST_TMPDIR}/mutant-ports.sh"
  sed 's/^LISTEN=.*/LISTEN=""/' "$SCRIPT" >"$mutant"
  ! cmp -s "$SCRIPT" "$mutant"
  echo "LISTEN 0 4096 127.0.0.1:34777 0.0.0.0:*" >>"$FAKE_DIR/ss"
  run_fixture "$mutant"
  [ "$status" -eq 0 ]
  [ "$(check_sev port.34777)" = "pass" ]
}

# --- Tier 2: live host --------------------------------------------------

live_prereqs() {
  unset DOCKER_BIN KIND_BIN KUBECTL_BIN SS_BIN IP_BIN SUDO_BIN MEMINFO_FILE \
    INOTIFY_WATCHES_FILE INOTIFY_INSTANCES_FILE
  docker info >/dev/null 2>&1 || skip "docker unreachable"
}

@test "P2PRE live: real-host audit emits valid JSON whose status matches the exit code" {
  live_prereqs
  run bash "$SCRIPT" --quiet
  [ "$status" -le 1 ]
  jq -e '.task == "SLDC-P2-PRE" and (.checks | length) >= 20' "$AUDIT_JSON"
  if [ "$status" -eq 0 ]; then jq -e '.status == "pass"' "$AUDIT_JSON"; else jq -e '.status == "fail" and .summary.blockers > 0' "$AUDIT_JSON"; fi
}

@test "P2PRE live mutation: a real listener on a free gated port is detected as a blocker" {
  live_prereqs
  command -v nc >/dev/null || skip "nc unavailable"
  port=34788
  ss -tlnH | awk '{print $4}' | grep -qE ":${port}\$" && skip "port ${port} already bound"
  nc -l 127.0.0.1 "$port" </dev/null >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do ss -tlnH | awk '{print $4}' | grep -qE ":${port}\$" && break; sleep 0.1; done
  P2_HOST_PORTS="$port" run bash "$SCRIPT" --quiet
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ "$(check_sev "port.${port}")" = "blocker" ]
}

@test "P2PRE live: --l3-probe proves static .10/.20 IPs and bidirectional reachability, leaving no residue" {
  [ "${P2_LIVE_L3:-0}" = 1 ] || skip "set P2_LIVE_L3=1 to create the disposable probe network"
  live_prereqs
  run bash "$SCRIPT" --quiet --l3-probe
  [ "$(check_sev l3.probe)" = "pass" ]
  run bash -c "docker network ls --format '{{.Name}}' | grep -c '^sldc-p2-preflight-' || true"
  [ "$output" = "0" ]
}
