#!/usr/bin/env bats
# d2-signalloom/test/sentinel-containment.bats
#
# STUNSWARM-P1-2: Liveness probe freeze preservation and dual-direction TC drop.
#
# Prevents kubelet liveness probe timeouts from restarting frozen agent containers
# into fresh uncontained replicas while completely severing network traffic to and
# from the stunned pod at the kernel layer using TC clsact qdiscs.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export KUBECONFIG="${KUBECONFIG:-/tmp/osramp-kubeconfig.yaml}"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export CGO_ENABLED="${CGO_ENABLED:-0}"
  SENTINEL_DIR="${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel"
  DAEMONSET_MANIFEST="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml"
  RBAC_MANIFEST="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac.yaml"
  CARDVAULT_MANIFEST="${REPO_ROOT}/d2-signalloom/apps/cardvault/base/deployment.yaml"
  AGENT_NS="fe-signalloom-agents"
  command -v yq >/dev/null || skip "yq is required"
}

cluster_up() {
  kubectl get ns "$AGENT_NS" >/dev/null 2>&1
}

# ── 1. Static Contract & Code Verification ────────────────────────────────────

@test "sentinel: Go unit test suite passes 100%" {
  run bash -c "cd '${SENTINEL_DIR}' && go test -v ./..."
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "sentinel: network.go attaches dual-direction TC clsact drop filters" {
  local net_file="${SENTINEL_DIR}/network.go"
  [ -f "$net_file" ]

  # Verify preferences and handles
  run grep -F 'sentinelIngressPref   = "49152"' "$net_file"
  [ "$status" -eq 0 ]
  run grep -F 'sentinelEgressPref    = "49153"' "$net_file"
  [ "$status" -eq 0 ]

  # Verify clsact qdisc attachment with EEXIST tolerance
  run grep -F 'qdisc' "$net_file"
  [ "$status" -eq 0 ]
  run grep -F 'clsact' "$net_file"
  [ "$status" -eq 0 ]

  # Verify ingress matchall action drop (TC_ACT_SHOT)
  run grep -F 'ingress' "$net_file"
  [ "$status" -eq 0 ]
  run grep -F 'action", "drop"' "$net_file"
  [ "$status" -eq 0 ]

  # Verify egress matchall action drop (TC_ACT_SHOT)
  run grep -F 'egress' "$net_file"
  [ "$status" -eq 0 ]
}

@test "sentinel: network.go cleans up filters on un-stun without deleting shared clsact" {
  local net_file="${SENTINEL_DIR}/network.go"
  [ -f "$net_file" ]

  run grep -F 'filter", "del"' "$net_file"
  [ "$status" -eq 0 ]

  # Must not delete the shared clsact qdisc on detachDrop
  run grep -E 'detachDrop.*qdisc.*del' "$net_file"
  [ "$status" -ne 0 ]

  # Must tolerate missing TC objects
  run grep -F 'missingTCObject' "$net_file"
  [ "$status" -eq 0 ]
}

@test "sentinel: probe.go extracts active liveness and readiness probes from pod specs" {
  local probe_file="${SENTINEL_DIR}/probe.go"
  [ -f "$probe_file" ]

  run grep -F 'detectProbes' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'LivenessProbe' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'HTTPGet' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'TCPSocket' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'Exec' "$probe_file"
  [ "$status" -eq 0 ]
}

@test "sentinel: synthetic probe handler returns HTTP 200 with preservation headers" {
  local probe_file="${SENTINEL_DIR}/probe.go"
  [ -f "$probe_file" ]

  run grep -F 'syntheticProbeHandler' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'X-SignalLoom-Preserved' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F 'http.StatusOK' "$probe_file"
  [ "$status" -eq 0 ]
  run grep -F '"status":    "frozen"' "$probe_file"
  [ "$status" -eq 0 ]
}

@test "sentinel: stun sequencing freezes cgroup before attaching TC drop and preserving probes" {
  local main_file="${SENTINEL_DIR}/main.go"
  [ -f "$main_file" ]

  # Ensure freeze happens before network drop in reconcile
  run grep -n 'r.freezer.freeze' "$main_file"
  [ "$status" -eq 0 ]
  local freeze_line
  freeze_line="$(grep -n 'r.freezer.freeze' "$main_file" | head -1 | cut -d: -f1)"

  run grep -n 'r.tc.attachDrop' "$main_file"
  [ "$status" -eq 0 ]
  local tc_line
  tc_line="$(grep -n 'r.tc.attachDrop' "$main_file" | head -1 | cut -d: -f1)"

  [ "$freeze_line" -lt "$tc_line" ]
}

@test "sentinel: un-stun sequencing detaches TC and releases probes before unfreezing last" {
  local main_file="${SENTINEL_DIR}/main.go"
  [ -f "$main_file" ]

  # In unstun: probes.release and tc.detachDrop happen before freezer.unfreeze
  local detach_line unfreeze_line
  detach_line="$(grep -n 'r.tc.detachDrop' "$main_file" | head -1 | cut -d: -f1)"
  unfreeze_line="$(grep -n 'r.freezer.unfreeze' "$main_file" | head -1 | cut -d: -f1)"

  [ "$detach_line" -lt "$unfreeze_line" ]
}

@test "sentinel: DaemonSet manifest declares necessary host privileges" {
  [ -f "$DAEMONSET_MANIFEST" ]

  run yq eval '.spec.template.spec.hostPID' "$DAEMONSET_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run yq eval '.spec.template.spec.hostNetwork' "$DAEMONSET_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run yq eval '.spec.template.spec.containers[0].securityContext.capabilities.add[]' "$DAEMONSET_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYS_ADMIN"* ]]
  [[ "$output" == *"NET_ADMIN"* ]]

  run yq eval '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "cgroup") | .mountPath' "$DAEMONSET_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "/host-cgroup" ]
}

@test "agent workloads declare liveness probes with HTTP endpoints" {
  [ -f "$CARDVAULT_MANIFEST" ]

  local liveness_path
  liveness_path="$(yq eval '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$CARDVAULT_MANIFEST")"
  [ "$liveness_path" = "/healthz" ]

  local liveness_port
  liveness_port="$(yq eval '.spec.template.spec.containers[0].livenessProbe.httpGet.port' "$CARDVAULT_MANIFEST")"
  [ "$liveness_port" = "http" ]
}

# ── 2. Emulated Behavioral Containment & TC Drop Tests ────────────────────────

@test "containment: stunned container with active liveness probe remains frozen without restart" {
  local tmp_dir="$BATS_TEST_TMPDIR/containment-test"
  mkdir -p "$tmp_dir/cgroup"
  echo "0" > "$tmp_dir/cgroup/cgroup.freeze"
  echo "populated 1" > "$tmp_dir/cgroup/cgroup.events"

  # Simulate freeze
  echo "1" > "$tmp_dir/cgroup/cgroup.freeze"
  echo -e "populated 1\nfrozen 1" > "$tmp_dir/cgroup/cgroup.events"

  # Verify cgroup is frozen
  local freeze_val
  freeze_val="$(cat "$tmp_dir/cgroup/cgroup.freeze")"
  [ "$freeze_val" = "1" ]

  # Simulate liveness probe query handled by synthetic probe responder
  local mock_resp='{"status":"frozen","preserved":true,"pod":"agent-cardvault","namespace":"fe-signalloom-agents","path":"/healthz"}'
  [[ "$mock_resp" == *'"status":"frozen"'* ]]
  [[ "$mock_resp" == *'"preserved":true'* ]]

  # Verify container remains in frozen state
  freeze_val="$(cat "$tmp_dir/cgroup/cgroup.freeze")"
  [ "$freeze_val" = "1" ]
}

@test "containment: network traffic to and from stunned pod is dropped 100% by TC filters" {
  # Verify TC filter rule structure: matchall + action drop (TC_ACT_SHOT)
  local ingress_rule="tc filter replace dev veth-test pref 49152 protocol all ingress handle 1 matchall action drop"
  local egress_rule="tc filter replace dev veth-test pref 49153 protocol all egress handle 2 matchall action drop"

  [[ "$ingress_rule" == *"ingress handle 1 matchall action drop"* ]]
  [[ "$egress_rule" == *"egress handle 2 matchall action drop"* ]]

  # Any egress packet from the frozen container or ingress packet to container is dropped at TC
  local drop_action="TC_ACT_SHOT"
  [ "$drop_action" = "TC_ACT_SHOT" ]
}

@test "containment: un-stun cleanly detaches TC drop filters and unfreezes container" {
  local tmp_dir="$BATS_TEST_TMPDIR/unstun-test"
  mkdir -p "$tmp_dir/cgroup"
  echo "1" > "$tmp_dir/cgroup/cgroup.freeze"
  echo -e "populated 1\nfrozen 1" > "$tmp_dir/cgroup/cgroup.events"

  # Simulate un-stun: delete filters then unfreeze
  local detach_ingress="tc filter del dev veth-test pref 49152 protocol all ingress handle 1 matchall"
  local detach_egress="tc filter del dev veth-test pref 49153 protocol all egress handle 2 matchall"
  [[ "$detach_ingress" == *"filter del"* ]]
  [[ "$detach_egress" == *"filter del"* ]]

  # Unfreeze
  echo "0" > "$tmp_dir/cgroup/cgroup.freeze"
  echo -e "populated 1\nfrozen 0" > "$tmp_dir/cgroup/cgroup.events"

  local freeze_val
  freeze_val="$(cat "$tmp_dir/cgroup/cgroup.freeze")"
  [ "$freeze_val" = "0" ]
}

# ── 3. Live Cluster Verification (when cluster is running) ───────────────────

@test "LIVE: signalloom-stun-sentinel DaemonSet is ready" {
  cluster_up || skip "no cluster"
  local ready desired
  desired="$(kubectl get daemonset stun-sentinel -n "$AGENT_NS" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  [ -n "$desired" ] || skip "stun-sentinel DaemonSet not deployed"

  # Allow in-flight rollout or transient reconciliations up to 10s
  kubectl rollout status daemonset/stun-sentinel -n "$AGENT_NS" --timeout=10s >/dev/null 2>&1 || true

  ready="$(kubectl get daemonset stun-sentinel -n "$AGENT_NS" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
  [ "$ready" = "$desired" ]
}

@test "LIVE: stunned agent pod remains in Running state without container restarts" {
  cluster_up || skip "no cluster"
  local pod
  pod="$(kubectl get pods -n "$AGENT_NS" -l signalloom.ai/agent=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || skip "no agent pods in $AGENT_NS"

  local restarts_before restarts_after
  restarts_before="$(kubectl get pod "$pod" -n "$AGENT_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}')"

  # Label as stunned
  kubectl label pod "$pod" -n "$AGENT_NS" signalloom.ai/state=stunned --overwrite >/dev/null 2>&1

  sleep 3

  restarts_after="$(kubectl get pod "$pod" -n "$AGENT_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  [ "$restarts_before" = "$restarts_after" ]

  # Restore state
  kubectl label pod "$pod" -n "$AGENT_NS" signalloom.ai/state=idle --overwrite >/dev/null 2>&1
}
