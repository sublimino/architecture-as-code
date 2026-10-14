#!/usr/bin/env bats
#
# scripts/prelive-clean-down.sh --check must read node readiness from the
# STATUS column exactly. A substring match for "Ready" also matches
# "NotReady", so a cluster whose nodes are all NotReady was reported Ready.
#
# Offline: kubectl, flux, systemctl and curl are stubs; only the node line of
# the audit is asserted.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  script="$root/scripts/prelive-clean-down.sh"
  [ -f "$script" ]
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  nodes="$BATS_TEST_TMPDIR/nodes"
  cat >"$bin/kubectl" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "get nodes" ]; then cat "$nodes"; exit 0; fi
exit 1
EOF
  local n
  for n in flux systemctl curl; do
    printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/$n"
  done
  chmod +x "$bin"/*
}

audit_with_nodes() {
  printf '%s' "$1" >"$nodes"
  run env PATH="$bin:$PATH" KUBECONFIG=/dev/null "$script" --check
  # The audit fails overall (stubbed endpoints); only the node verdict matters.
  [[ "$output" == *"PRE-LIVE VERIFICATION"* ]]
}

@test "PRELIVE a single NotReady node is reported NOT Ready" {
  audit_with_nodes $'kind-control-plane   NotReady   control-plane   5m   v1.33.1\n'
  [[ "$output" == *"node is NOT Ready"* ]]
  [[ "$output" != *"node is Ready"* ]]
}

@test "PRELIVE a single Ready node is reported Ready" {
  audit_with_nodes $'kind-control-plane   Ready   control-plane   5m   v1.33.1\n'
  [[ "$output" == *"node is Ready"* ]]
  [[ "$output" != *"node is NOT Ready"* ]]
}

@test "PRELIVE one NotReady node among Ready ones is reported NOT Ready" {
  audit_with_nodes $'cp   Ready   control-plane   5m   v1.33.1\nw1   NotReady   <none>   5m   v1.33.1\n'
  [[ "$output" == *"node is NOT Ready"* ]]
  [[ "$output" != *"node is Ready"* ]]
}

@test "PRELIVE a cordoned Ready node still counts as Ready" {
  audit_with_nodes $'cp   Ready,SchedulingDisabled   control-plane   5m   v1.33.1\n'
  [[ "$output" == *"node is Ready"* ]]
  [[ "$output" != *"node is NOT Ready"* ]]
}

@test "PRELIVE no nodes at all is reported NOT Ready" {
  audit_with_nodes ''
  [[ "$output" == *"node is NOT Ready"* ]]
  [[ "$output" != *"node is Ready"* ]]
}
