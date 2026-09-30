#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/dual-cluster-networking.bats : SLDC-P2-1 dual Kind cluster networking suite
#
# @id     sldc-p2-1-dual-cluster-networking
# @target scripts/dual-cluster-up.sh, scripts/dual-cluster-down.sh,
#         scripts/lib/dual-cluster.sh, infra/kind/*.yaml,
#         d2-infra/components/coredns/cross-cluster-stubs.yaml
# @doc    docs/eap/SLDC-P2-DUAL-CLUSTER.md
#
# Tier 1 (hermetic, always runs): manifest contract, the Corefile splice and
# the loop-safety lint (each driven red by a mutation), and the up/down
# orchestration against fake docker/kind/kubectl binaries that record argv.
#
# Tier 2 (live): runs against kind-osramp + kind-signalloom-hub. Every DNS and
# ICMP assertion execs INSIDE deploy/probe; a host-side lookup would be a
# false green. When the hub context is absent the tier skips, unless
# SLDC_DUAL_CLUSTER_LIVE=1, in which case absence FAILS: a CI lane that
# expects the topology must not go green without it.
# The DNS-stub mutation test rewrites kind-osramp's managed block to forward
# to 192.0.2.1 (TEST-NET-1) and restores it in teardown. It only runs with
# SLDC_LIVE_MUTATION=1, because it perturbs the shared cluster's SLDC zones.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/dual-cluster.sh"
  UP="$REPO_ROOT/scripts/dual-cluster-up.sh"
  DOWN="$REPO_ROOT/scripts/dual-cluster-down.sh"
  OSR_YAML="$REPO_ROOT/infra/kind/cluster-osramp.yaml"
  HUB_YAML="$REPO_ROOT/infra/kind/cluster-signalloom-hub.yaml"
  STUBS="$REPO_ROOT/d2-infra/components/coredns/cross-cluster-stubs.yaml"
  PROBE="$REPO_ROOT/infra/kind/probe.yaml"
  # shellcheck source=scripts/lib/dual-cluster.sh
  source "$LIB"
}

stub_block() { yq 'select(.kind == "ConfigMap").data["stub.server"]' "$STUBS"; }

live_or_skip() {
  command -v kubectl >/dev/null || { [ "${SLDC_DUAL_CLUSTER_LIVE:-0}" = 1 ] && fail "kubectl missing"; skip "kubectl missing"; }
  if ! kubectl --context kind-signalloom-hub version --request-timeout=5s >/dev/null 2>&1 \
    || ! kubectl --context kind-osramp version --request-timeout=5s >/dev/null 2>&1; then
    [ "${SLDC_DUAL_CLUSTER_LIVE:-0}" = 1 ] && fail "dual-cluster topology not reachable (SLDC_DUAL_CLUSTER_LIVE=1)"
    skip "kind-osramp/kind-signalloom-hub not reachable; run scripts/dual-cluster-up.sh"
  fi
}

fail() { echo "$*" >&2; return 1; }

# `! cmd` never fails a bats test (errexit ignores negation), so refutations
# must return non-zero explicitly.
refute_called() { if grep -q "$1" "$CALLS"; then echo "unexpected call: $1" >&2; return 1; fi; }

# First A record in a busybox nslookup answer section.
answer_ip() { awk '/^Name:/{n=1} n && /^Address/{print $NF; exit}'; }

# ---------------------------------------------------------------- tier 1 ----

@test "manifests: cluster names, API ports and subnets match Appendix B" {
  [ "$(yq '.name' "$OSR_YAML")" = osramp ]
  [ "$(yq '.networking.apiServerAddress' "$OSR_YAML")" = 127.0.0.1 ]
  [ "$(yq '.networking.apiServerPort' "$OSR_YAML")" = 34777 ]
  [ "$(yq '.networking.podSubnet' "$OSR_YAML")" = 10.244.0.0/16 ]
  [ "$(yq '.networking.serviceSubnet' "$OSR_YAML")" = 10.96.0.0/16 ]
  [ "$(yq '.name' "$HUB_YAML")" = signalloom-hub ]
  [ "$(yq '.networking.apiServerAddress' "$HUB_YAML")" = 127.0.0.1 ]
  [ "$(yq '.networking.apiServerPort' "$HUB_YAML")" = 34788 ]
  [ "$(yq '.networking.podSubnet' "$HUB_YAML")" = 10.245.0.0/16 ]
  [ "$(yq '.networking.serviceSubnet' "$HUB_YAML")" = 10.97.0.0/16 ]
}

@test "manifests: workload node mounts cgroup rw, modules and BTF ro" {
  [ "$(yq '.nodes[0].extraMounts[] | select(.containerPath == "/sys/fs/cgroup") | .readOnly' "$OSR_YAML")" = false ]
  [ "$(yq '.nodes[0].extraMounts[] | select(.containerPath == "/lib/modules") | .readOnly' "$OSR_YAML")" = true ]
  [ "$(yq '.nodes[0].extraMounts[] | select(.containerPath == "/sys/kernel/btf") | .readOnly' "$OSR_YAML")" = true ]
}

@test "manifests: gateway host ports bind only on the hub, only on loopback" {
  [ "$(yq '[.nodes[].extraPortMappings[]?] | length' "$OSR_YAML")" = 0 ]
  run yq -r '.nodes[0].extraPortMappings[] | "\(.hostPort)=\(.containerPort)@\(.listenAddress)"' "$HUB_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = $'31443=31443@127.0.0.1\n30080=30080@127.0.0.1' ]
}

@test "manifests: both nodes pin the same node image by digest" {
  local a b
  a="$(yq '.nodes[0].image' "$OSR_YAML")"
  b="$(yq '.nodes[0].image' "$HUB_YAML")"
  [ "$a" = "$b" ]
  [[ "$a" == kindest/node:v1.36.1@sha256:* ]]
}

@test "manifests: hub pins kube-proxy iptables mode (NodePorts on the bridge NIC)" {
  [ "$(yq '.networking.kubeProxyMode' "$HUB_YAML")" = iptables ]
}

@test "lib: bridge contract constants" {
  [ "$SLDC_BRIDGE_NAME" = signalloom-bridge ]
  [ "$SLDC_BRIDGE_CIDR" = 172.19.0.0/16 ]
  [ "$SLDC_OSRAMP_IP" = 172.19.0.10 ]
  [ "$SLDC_HUB_IP" = 172.19.0.20 ]
  [ "$SLDC_OSRAMP_CTX" = kind-osramp ]
  [ "$SLDC_HUB_CTX" = kind-signalloom-hub ]
}

@test "stubs: shipped block forwards each zone to its owner and passes the lint" {
  local blk
  blk="$(stub_block)"
  [[ "$blk" == *"signalloom.hub:53 {"*"forward . 172.19.0.20:53"* ]]
  [[ "$blk" == *"osramp.local:53 {"*"forward . 172.19.0.10:53"* ]]
  run sldc_lint_stub_block "$blk"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stubs: bridge responder is authoritative, binds the bridge IP, never forwards" {
  local cf
  cf="$(yq 'select(.kind == "ConfigMap").data.Corefile' "$STUBS")"
  [[ "$cf" == *'bind {$SLDC_BRIDGE_IP}'* ]]
  [[ "$cf" == *'IN A {$SLDC_BRIDGE_IP}'* ]]
  [[ "$cf" != *forward* ]]
  [[ "$cf" != *fallthrough* ]]
  [ "$(yq 'select(.kind == "Deployment").spec.template.spec.hostNetwork' "$STUBS")" = true ]
}

@test "lint mutation: self-forward (hub zone -> workload IP) is a loop and is rejected" {
  run sldc_lint_stub_block "$(stub_block | sed 's/172.19.0.20:53/172.19.0.10:53/')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected its owner '172.19.0.20:53'"* ]]
}

@test "lint mutation: fallthrough is rejected" {
  run sldc_lint_stub_block "$(stub_block | sed 's/^\( *\)errors/\1errors\n\1fallthrough/')"
  [ "$status" -ne 0 ]
  [[ "$output" == *fallthrough* ]]
}

@test "lint mutation: a root zone or foreign zone server block is rejected" {
  run sldc_lint_stub_block "$(printf '.:53 {\n    forward . 172.19.0.20:53\n}\n')"
  [ "$status" -ne 0 ]
  run sldc_lint_stub_block "$(stub_block | sed 's/^osramp.local:53/cluster.local:53/')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cluster.local:53'"* ]]
}

@test "lint mutation: a zone both templated and forwarded is rejected" {
  local blk
  blk="$(stub_block | sed 's/^\( *\)cache 30/\1template IN A signalloom.hub {\n\1}\n\1cache 30/')"
  run sldc_lint_stub_block "$blk"
  [ "$status" -ne 0 ]
  [[ "$output" == *"both forwarded and templated"* ]]
}

@test "splice: appends the managed block, keeps .:53 intact, and is idempotent" {
  local base once twice
  base=$'.:53 {\n    errors\n    forward . /etc/resolv.conf\n    loop\n}'
  once="$(printf '%s\n' "$base" | sldc_splice_corefile "$(stub_block)")"
  twice="$(printf '%s\n' "$once" | sldc_splice_corefile "$(stub_block)")"
  [ "$once" = "$twice" ]
  [[ "$once" == "$base"* ]]
  [ "$(grep -c '^# BEGIN sldc-cross-cluster' <<<"$once")" -eq 1 ]
  [ "$(grep -c '^signalloom.hub:53' <<<"$once")" -eq 1 ]
}

@test "splice: replaces a stale managed block instead of appending a second" {
  local base stale next
  base=$'.:53 {\n    errors\n}'
  stale="$(printf '%s\n' "$base" | sldc_splice_corefile $'signalloom.hub:53 {\n    forward . 192.0.2.1:53\n}')"
  next="$(printf '%s\n' "$stale" | sldc_splice_corefile "$(stub_block)")"
  [[ "$next" != *192.0.2.1* ]]
  [ "$(grep -c '^# BEGIN sldc-cross-cluster' <<<"$next")" -eq 1 ]
}

@test "strip: removes exactly the managed block (teardown restores the original)" {
  local base spliced
  base=$'.:53 {\n    errors\n    loop\n}'
  spliced="$(printf '%s\n' "$base" | sldc_splice_corefile "$(stub_block)")"
  [ "$(printf '%s\n' "$spliced" | sldc_strip_corefile)" = "$base" ]
}

@test "probe: in-pod probe carries NET_RAW and a scoped egress policy for default-deny" {
  [ "$(yq 'select(.kind == "Deployment").spec.template.spec.containers[0].securityContext.capabilities.add[0]' "$PROBE")" = NET_RAW ]
  [ "$(yq 'select(.kind == "NetworkPolicy").spec.podSelector.matchLabels["app.kubernetes.io/name"]' "$PROBE")" = probe ]
  [ "$(yq 'select(.kind == "NetworkPolicy").spec.egress[1].to[0].ipBlock.cidr' "$PROBE")" = 172.19.0.0/16 ]
}

# --- orchestration against fakes ---------------------------------------------

# Fake docker/kind/kubectl. Each logs argv to $CALLS. State lives in files
# under $FAKE: networks (name|subnet|containers), clusters, node IPs.
make_fakes() {
  FAKE="$BATS_TEST_TMPDIR/fake"; CALLS="$FAKE/calls"
  mkdir -p "$FAKE/bin"; : >"$CALLS"
  cat >"$FAKE/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS"
case "$1 $2" in
  "network ls") cut -d'|' -f1 "$FAKE/networks" ;;
  "network inspect")
    line="$(grep "^$3|" "$FAKE/networks")" || exit 1
    case "$*" in
      *Subnet*) echo "$line" | cut -d'|' -f2 ;;
      *"len .Containers"*) echo "$line" | cut -d'|' -f3 ;;
      *"range .Containers"*) echo "" ;;
    esac ;;
  "network rm") grep -v "^$3|" "$FAKE/networks" >"$FAKE/n2"; mv "$FAKE/n2" "$FAKE/networks" ;;
  "network create") echo "${@: -1}|$(printf '%s\n' "$@" | grep -A1 -- --subnet | tail -1)|0" >>"$FAKE/networks" ;;
  "network connect") echo "$6=$4" >>"$FAKE/ips" ;;
  "network disconnect") : ;;
  inspect*)
    case "$*" in
      *NetworkSettings*) grep "^$2=" "$FAKE/ips" 2>/dev/null | tail -1 | cut -d= -f2 ;;
      *) exit 0 ;;
    esac ;;
  "ps -a"|"volume ls") : ;;
  "volume inspect") exit 1 ;;
  *) : ;;
esac
EOF
  cat >"$FAKE/bin/kind" <<'EOF'
#!/usr/bin/env bash
echo "kind $*" >>"$CALLS"
case "$1 $2" in
  "get clusters") cat "$FAKE/clusters" ;;
  "create cluster") echo "$4" >>"$FAKE/clusters" ;;
  "delete cluster") grep -vx "$4" "$FAKE/clusters" >"$FAKE/c2"; mv "$FAKE/c2" "$FAKE/clusters" ;;
esac
EOF
  cat >"$FAKE/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
case "$*" in
  *"config current-context"*) echo kind-osramp ;;
  *"get configmap sldc-cross-cluster-stubs"*) yq -o json 'select(.kind=="ConfigMap")' "$STUBS" ;;
  *"get configmap coredns"*) printf '{"data":{"Corefile":".:53 {\\n    errors\\n}"}}\n' ;;
  *"exec deploy/probe"*) printf 'Server: 10.96.0.10\n\nName: x\nAddress: 172.19.0.20\n' ;;
  *"create configmap"*) echo "apiVersion: v1" ;;
  *"apply -f -"*|*"patch"*) cat >/dev/null ;;
esac
exit 0
EOF
  chmod +x "$FAKE/bin/"*
  export FAKE CALLS STUBS DOCKER_BIN="$FAKE/bin/docker" KIND_BIN="$FAKE/bin/kind" \
    KUBECTL_BIN="$FAKE/bin/kubectl" CILIUM_BIN=/bin/true SLDC_REGISTRY_CACHE=0 SLDC_SLEEP=true
}

@test "up: refuses when the bridge CIDR is held and --reclaim-subnet is absent" {
  make_fakes
  printf 'kind|172.18.0.0/16|3\nclawdbot_default|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\n' >"$FAKE/clusters"
  run bash "$UP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"held by docker network 'clawdbot_default'"* ]]
  refute_called 'network rm'
}

@test "up: --reclaim-subnet never removes a network with containers attached" {
  make_fakes
  printf 'busy|172.19.0.0/16|2\n' >"$FAKE/networks"
  printf 'osramp\n' >"$FAKE/clusters"
  run bash "$UP" --reclaim-subnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to reclaim 'busy'"* ]]
  refute_called 'network rm'
}

@test "up: attaches existing osramp (no recreate), creates hub, pins bridge IPs, wires DNS" {
  make_fakes
  printf 'clawdbot_default|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\n' >"$FAKE/clusters"
  run bash "$UP" --reclaim-subnet
  [ "$status" -eq 0 ]
  # rm then create, adjacent (nothing may claim the /16 in between)
  run grep -n 'docker network \(rm\|create\)' "$CALLS"
  [[ "${lines[0]}" == *"network rm clawdbot_default"* ]]
  [[ "${lines[1]}" == *"network create --driver bridge --subnet 172.19.0.0/16 --gateway 172.19.0.1"*"signalloom-bridge"* ]]
  [ $(( ${lines[1]%%:*} - ${lines[0]%%:*} )) -eq 1 ]
  refute_called 'kind create cluster --name osramp'
  grep -q 'kind create cluster --name signalloom-hub --config .*infra/kind/cluster-signalloom-hub.yaml' "$CALLS"
  grep -q 'docker network connect --ip 172.19.0.10 signalloom-bridge osramp-control-plane' "$CALLS"
  grep -q 'docker network connect --ip 172.19.0.20 signalloom-bridge signalloom-hub-control-plane' "$CALLS"
  grep -q 'kubectl --context kind-osramp -n kube-system create configmap sldc-bridge-identity --from-literal=SLDC_ZONE=osramp.local --from-literal=SLDC_BRIDGE_IP=172.19.0.10' "$CALLS"
  grep -q 'kubectl --context kind-signalloom-hub -n kube-system create configmap sldc-bridge-identity --from-literal=SLDC_ZONE=signalloom.hub --from-literal=SLDC_BRIDGE_IP=172.19.0.20' "$CALLS"
  [ "$(grep -c 'patch configmap coredns' "$CALLS")" -eq 2 ]
  # kind create's context switch is undone
  grep -q 'kubectl config use-context kind-osramp' "$CALLS"
}

@test "up: a fresh osramp is created from its manifest and gets Cilium" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  : >"$FAKE/clusters"
  export CILIUM_BIN="$FAKE/bin/cilium"
  printf '#!/usr/bin/env bash\necho "cilium $*" >>"$CALLS"\n' >"$CILIUM_BIN"; chmod +x "$CILIUM_BIN"
  run bash "$UP"
  [ "$status" -eq 0 ]
  grep -q 'kind create cluster --name osramp --config .*infra/kind/cluster-osramp.yaml' "$CALLS"
  grep -q 'cilium install --context kind-osramp --version 1.16.7' "$CALLS"
}

@test "up mutation: a stub block that fails the lint aborts before touching CoreDNS" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  sed 's/forward . 172.19.0.20:53/forward . 172.19.0.10:53/' "$STUBS" >"$BATS_TEST_TMPDIR/bad.yaml"
  STUBS="$BATS_TEST_TMPDIR/bad.yaml" STUBS_MANIFEST="$BATS_TEST_TMPDIR/bad.yaml" run bash "$UP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fails the loop-safety lint"* ]]
  refute_called 'patch configmap coredns'
}

@test "up: verify fails when in-pod DNS does not return the hub bridge IP" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  sed -i 's/Address: 172.19.0.20/Address: 192.0.2.1/' "$FAKE/bin/kubectl"
  SLDC_DNS_TIMEOUT=0 run bash "$UP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not resolve to 172.19.0.20"* ]]
}

@test "down: default keeps the shared osramp cluster and unwires it" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  echo 'osramp-control-plane=172.19.0.10' >"$FAKE/ips"
  run bash "$DOWN"
  [ "$status" -eq 0 ]
  grep -q 'kind delete cluster --name signalloom-hub' "$CALLS"
  refute_called 'kind delete cluster --name osramp'
  grep -q 'delete deployment sldc-bridge-dns' "$CALLS"
  grep -q 'docker network disconnect signalloom-bridge osramp-control-plane' "$CALLS"
  refute_called 'network rm'
}

@test "down: --delete-osramp --remove-bridge removes both clusters and the network" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  run bash "$DOWN" --delete-osramp --remove-bridge
  [ "$status" -eq 0 ]
  grep -q 'kind delete cluster --name osramp' "$CALLS"
  grep -q 'docker network rm signalloom-bridge' "$CALLS"
}

@test "down: a hub name aliasing the shared osramp cluster is refused (exit 2, nothing deleted)" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  SLDC_HUB_CLUSTER=osramp run bash "$DOWN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SLDC_HUB_CLUSTER 'osramp' is the shared workload cluster"* ]]
  refute_called 'kind delete'
}

@test "down: unknown flag exits 2 before touching anything" {
  make_fakes
  run bash "$DOWN" --delete-everything
  [ "$status" -eq 2 ]
  [[ "$output" == *"--delete-osramp"* ]]
  [ ! -s "$CALLS" ]
}

@test "down: a missing kind binary fails (exit 1) instead of reporting a clean teardown" {
  make_fakes
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  KIND_BIN="$BATS_TEST_TMPDIR/absent/kind" run bash "$DOWN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: $BATS_TEST_TMPDIR/absent/kind"* ]]
  [[ "$output" != *"teardown complete"* ]]
}

@test "up: a missing docker binary fails (exit 1) and names the tool" {
  make_fakes
  DOCKER_BIN="$BATS_TEST_TMPDIR/absent/docker" run bash "$UP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: $BATS_TEST_TMPDIR/absent/docker"* ]]
}

@test "up: a missing kind binary fails before any cluster create is attempted" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  KIND_BIN="$BATS_TEST_TMPDIR/absent/kind" run bash "$UP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: $BATS_TEST_TMPDIR/absent/kind"* ]]
  [[ "$output" != *"kind create"* ]]
}

@test "up: re-running against a complete topology creates, connects and recreates nothing" {
  make_fakes
  printf 'signalloom-bridge|172.19.0.0/16|0\n' >"$FAKE/networks"
  printf 'osramp\nsignalloom-hub\n' >"$FAKE/clusters"
  run bash "$UP"
  [ "$status" -eq 0 ]
  : >"$CALLS"
  run bash "$UP"
  [ "$status" -eq 0 ]
  refute_called 'kind create'
  refute_called 'network create'
  refute_called 'network connect'
  refute_called 'network rm'
}

# ---------------------------------------------------------------- tier 2 ----

@test "live: kind get clusters lists osramp and signalloom-hub" {
  live_or_skip
  run kind get clusters
  [ "$status" -eq 0 ]
  grep -qx osramp <<<"$output"
  grep -qx signalloom-hub <<<"$output"
}

@test "live: both contexts return a Ready control-plane node" {
  live_or_skip
  local ctx
  for ctx in kind-osramp kind-signalloom-hub; do
    run kubectl --context "$ctx" get nodes -l node-role.kubernetes.io/control-plane \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
    [ "$status" -eq 0 ]
    [ "$output" = True ]
  done
}

@test "live: nodes hold their fixed IPs on signalloom-bridge 172.19.0.0/16" {
  live_or_skip
  [ "$(docker network inspect signalloom-bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')" = 172.19.0.0/16 ]
  [ "$(sldc_container_ip osramp-control-plane signalloom-bridge)" = 172.19.0.10 ]
  [ "$(sldc_container_ip signalloom-hub-control-plane signalloom-bridge)" = 172.19.0.20 ]
}

@test "live: ICMP osramp pod -> hub 172.19.0.20 with 0% loss" {
  live_or_skip
  run kubectl --context kind-osramp -n default exec deploy/probe -- ping -c 3 -W 2 172.19.0.20
  [ "$status" -eq 0 ]
  [[ "$output" == *" 0% packet loss"* ]]
}

@test "live: ICMP hub pod -> osramp 172.19.0.10 with 0% loss" {
  live_or_skip
  run kubectl --context kind-signalloom-hub -n default exec deploy/probe -- ping -c 3 -W 2 172.19.0.10
  [ "$status" -eq 0 ]
  [[ "$output" == *" 0% packet loss"* ]]
}

@test "live: in-pod DNS on osramp resolves signal-ingest.fe-signalloom.signalloom.hub -> 172.19.0.20" {
  live_or_skip
  run kubectl --context kind-osramp -n default exec deploy/probe -- nslookup signal-ingest.fe-signalloom.signalloom.hub
  [ "$status" -eq 0 ]
  [ "$(answer_ip <<<"$output")" = 172.19.0.20 ]
}

@test "live: in-pod DNS on the hub resolves agent-kusari.fe-signalloom-agents.osramp.local -> 172.19.0.10" {
  live_or_skip
  run kubectl --context kind-signalloom-hub -n default exec deploy/probe -- nslookup agent-kusari.fe-signalloom-agents.osramp.local
  [ "$status" -eq 0 ]
  [ "$(answer_ip <<<"$output")" = 172.19.0.10 ]
}

@test "live: cluster.local resolution is untouched on both clusters" {
  live_or_skip
  local ctx
  for ctx in kind-osramp kind-signalloom-hub; do
    run kubectl --context "$ctx" -n default exec deploy/probe -- nslookup kubernetes.default.svc.cluster.local
    [ "$status" -eq 0 ]
    [[ "$(answer_ip <<<"$output")" == 10.9[67].0.1 ]]
  done
}

@test "live: managed stub block is present in both Corefiles (catches a GitOps overwrite)" {
  live_or_skip
  local ctx cf
  for ctx in kind-osramp kind-signalloom-hub; do
    cf="$(kubectl --context "$ctx" -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
    [[ "$cf" == *"# BEGIN sldc-cross-cluster"*"forward . 172.19.0.20:53"*"forward . 172.19.0.10:53"*"# END sldc-cross-cluster"* ]]
  done
}

@test "live: no loop detection or Corefile parse errors in CoreDNS logs" {
  live_or_skip
  local ctx
  for ctx in kind-osramp kind-signalloom-hub; do
    run kubectl --context "$ctx" -n kube-system logs -l k8s-app=kube-dns --tail=300
    [ "$status" -eq 0 ]
    if grep -Eqi 'plugin/loop|Loop \(|Error during parsing' <<<"$output"; then echo "$output" >&2; return 1; fi
  done
}

@test "live: TCP by FQDN across the bridge in both directions" {
  live_or_skip
  # osramp -> hub: a throwaway NodePort web server on the hub, reached by name.
  kubectl --context kind-signalloom-hub -n default apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: sldc-echo, labels: {app: sldc-echo}}
spec:
  containers:
    - name: web
      image: docker.io/library/busybox:1.36.1
      command: ["sh", "-c", "echo sldc-echo-ok >/tmp/index.html && httpd -f -p 8080 -h /tmp"]
---
apiVersion: v1
kind: Service
metadata: {name: sldc-echo}
spec:
  type: NodePort
  selector: {app: sldc-echo}
  ports: [{port: 8080, targetPort: 8080, nodePort: 30081}]
EOF
  kubectl --context kind-signalloom-hub -n default wait --for=condition=Ready pod/sldc-echo --timeout=120s >/dev/null
  run kubectl --context kind-osramp -n default exec deploy/probe -- wget -qO- -T 5 http://sldc-echo.fe-signalloom.signalloom.hub:30081/
  kubectl --context kind-signalloom-hub -n default delete pod/sldc-echo service/sldc-echo --wait=false >/dev/null 2>&1 || true
  [ "$status" -eq 0 ]
  [ "$output" = sldc-echo-ok ]
  # hub -> osramp: TCP to the workload's bridge DNS responder, by name.
  run kubectl --context kind-signalloom-hub -n default exec deploy/probe -- nc -z -w 5 dns.osramp.local 53
  [ "$status" -eq 0 ]
}

@test "live mutation: stub pointed at unroutable 192.0.2.1 makes in-pod lookup fail, restore heals it" {
  live_or_skip
  [ "${SLDC_LIVE_MUTATION:-0}" = 1 ] || skip "perturbs kind-osramp SLDC zones; set SLDC_LIVE_MUTATION=1"
  local cf bad
  cf="$(kosr -n kube-system get configmap coredns -o json | jq -r '.data.Corefile')"
  bad="$(printf '%s\n' "$cf" | sldc_splice_corefile "$(stub_block | sed 's/172.19.0.20:53/192.0.2.1:53/')")"
  jq -n --arg c "$bad" '{data: {Corefile: $c}}' | kosr -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin >/dev/null
  kosr -n kube-system rollout restart deployment/coredns >/dev/null
  kosr -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null
  run kosr -n default exec deploy/probe -- nslookup signal-ingest.fe-signalloom.signalloom.hub
  local mutated_status="$status" mutated_output="$output"
  # restore via the production path, then prove it healed
  run bash "$UP" --skip-verify
  [ "$status" -eq 0 ]
  echo "mutated: rc=$mutated_status $mutated_output"
  [ "$mutated_status" -ne 0 ]
  [[ "$mutated_output" == *SERVFAIL* || "$mutated_output" == *"timed out"* || "$mutated_output" == *NXDOMAIN* ]]
  run kosr -n default exec deploy/probe -- nslookup signal-ingest.fe-signalloom.signalloom.hub
  [ "$status" -eq 0 ]
  [ "$(answer_ip <<<"$output")" = 172.19.0.20 ]
}
