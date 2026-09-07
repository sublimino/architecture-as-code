#!/usr/bin/env bats

setup() {
  slice_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  canonical="$slice_root/test/netassert-signalloom.yaml"
  deployed="$slice_root/apps/fe-signalloom/base/netassert-signalloom.yaml"
  checker="$slice_root/test/check-netassert-config-drift.sh"
}

@test "Netassert policy contract validates the committed configuration" {
  run bash "$checker"
  [ "$status" -eq 0 ]
}

@test "Netassert policy contract rejects a removed assertion" {
  mutated="$BATS_TEST_TMPDIR/removed.yaml"
  NAME=dashboard-to-spire-server-denied yq 'del(.[] | select(.name == strenv(NAME)))' "$canonical" > "$mutated"

  run env NETASSERT_CONFIG="$mutated" NETASSERT_DEPLOY_CONFIG="$mutated" bash "$checker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dashboard-to-spire-server-denied"* ]]
}

@test "Netassert policy contract rejects a widened deny destination" {
  mutated="$BATS_TEST_TMPDIR/widened.yaml"
  NAME=generic-agent-to-cardvault-denied yq '(.[] | select(.name == strenv(NAME)) | .dst.k8sResource.name) = "postgresql"' "$canonical" > "$mutated"

  run env NETASSERT_CONFIG="$mutated" NETASSERT_DEPLOY_CONFIG="$mutated" bash "$checker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"generic-agent-to-cardvault-denied"* ]]
}

@test "Netassert policy names are unique and stable" {
  run yq -e '[.[].name] | length == (unique | length)' "$canonical"
  [ "$status" -eq 0 ]
}

@test "Netassert runtime placeholders publish resolver label contracts" {
  run grep -F 'agent-patsy => namespace=fe-signalloom-agents label=signalloom.ai/agent=true' "$canonical"
  [ "$status" -eq 0 ]
  run grep -F 'supercred-cardvault-agent-pod => namespace=fe-signalloom-agents label=app.kubernetes.io/name=cardvault-agent,signalloom.ai/supercred=true' "$canonical"
  [ "$status" -eq 0 ]
  run grep -F 'envoy-gateway-pod => namespace=ingress label=gateway.envoyproxy.io/owning-gateway-name=cluster' "$canonical"
  [ "$status" -eq 0 ]
}

@test "SPIRE host-network enforcement limitation remains explicit" {
  run grep -F 'SPIRE agent uses hostNetwork; Kubernetes NetworkPolicy cannot prove its node-network enforcement.' "$canonical"
  [ "$status" -eq 0 ]
}
