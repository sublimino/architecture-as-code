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
  run bash "$checker"
  [ "$status" -eq 0 ]

  mutated="$BATS_TEST_TMPDIR/removed.yaml"
  NAME=dashboard-to-spire-server-denied yq 'del(.[] | select(.name == strenv(NAME)))' "$canonical" > "$mutated"

  run env NETASSERT_CONFIG="$mutated" NETASSERT_DEPLOY_CONFIG="$mutated" bash "$checker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dashboard-to-spire-server-denied"* ]]
}

@test "Netassert policy contract rejects a widened deny destination" {
  run bash "$checker"
  [ "$status" -eq 0 ]

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
  run grep -F 'agent-patsy => namespace=fe-signalloom-agents label=signalloom.ai/agent=true,signalloom.ai/framework=custom,netassert.signalloom.ai/fixture=generic-agent' "$canonical"
  [ "$status" -eq 0 ]
  run grep -F 'netassert-cardvault-probe-pod => namespace=fe-signalloom-agents label=app.kubernetes.io/name=cardvault-agent,signalloom.ai/supercred=true,bao.controlplane.io/consumer=cardvault-agent,netassert.signalloom.ai/fixture=cardvault-agent serviceAccount=cardvault-agent lifecycle=fleet-provisioned-sustained' "$canonical"
  [ "$status" -eq 0 ]
  run grep -F 'envoy-gateway-pod => namespace=ingress label=gateway.envoyproxy.io/owning-gateway-name=cluster' "$canonical"
  [ "$status" -eq 0 ]
}

@test "SPIRE server assertions reflect both NetworkPolicy halves" {
  bao_policy="$slice_root/infra/inf-bao/configs/base/networkpolicy.yaml"
  agent_policy="$slice_root/infra/agent-swarm/networkpolicy.yaml"

  run yq -e '[.[] | select(.name == "generic-agent-to-spire-server-denied" and .exitCode == 1)] | length == 1' "$canonical"
  [ "$status" -eq 0 ]
  run yq -e '[.[] | select(.name == "openbao-to-spire-server-allowed" and .exitCode == 0)] | length == 1' "$canonical"
  [ "$status" -eq 0 ]
  run bash -c 'yq -r '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-identity-plane-egress") | ([.spec.egress[] | select(.ports[]?.port == 8081)] | length == 1)'\'' "$1" 2>/dev/null | grep -qx true' _ "$agent_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -r '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-bao-spire-and-portal") | ([.spec.ingress[] | select((.from[]?.podSelector | keys | length) == 0)] | length == 1)'\'' "$1" 2>/dev/null | grep -qx true' _ "$bao_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -r '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-bao-spire-and-portal") | ([.spec.ingress[] | select(.ports[]?.port == 8081)] | length == 0)'\'' "$1" 2>/dev/null | grep -qx true' _ "$bao_policy"
  [ "$status" -eq 0 ]
}

@test "Credential probe contract matches egress and destination ingress selectors" {
  job_policy="$slice_root/apps/fe-signalloom/base/agents-cardvault-job.yaml"
  bao_policy="$slice_root/infra/inf-bao/configs/base/networkpolicy.yaml"
  cardvault_policy="$slice_root/apps/cardvault/base/networkpolicy.yaml"

  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-supercred-cardvault-egress")'\'' "$1" | yq -e '\''([.spec.egress[].to[].podSelector.matchLabels."app.kubernetes.io/name"] | sort | join(",")) == "cardvault,openbao"'\'' -' _ "$job_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -r '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-bao-spire-and-portal") | ([.spec.ingress[].from[] | select(.podSelector.matchLabels."bao.controlplane.io/consumer" == "cardvault-agent")] | length == 1)'\'' "$1" 2>/dev/null | grep -qx true' _ "$bao_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -r '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-cardvault-from-agents") | ([.spec.ingress[].from[] | select(.podSelector.matchLabels."bao.controlplane.io/consumer" == "cardvault-agent")] | length == 1)'\'' "$1" 2>/dev/null | grep -qx true' _ "$cardvault_policy"
  [ "$status" -eq 0 ]
}

@test "OpenBao assertions match caller egress and receiver ingress policies" {
  fe_policy="$slice_root/apps/fe-signalloom/base/networkpolicy.yaml"
  bao_policy="$slice_root/infra/inf-bao/configs/base/networkpolicy.yaml"

  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-portal-dependencies")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.ports[]?.port == 8200 and .to[].podSelector.matchLabels."app.kubernetes.io/name" == "openbao")] | length == 1'\'' -' _ "$fe_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-bao-spire-and-portal")'\'' "$1" | yq -e '\''[.spec.ingress[] | select(.ports[]?.port == 8200 and .from[].podSelector.matchLabels."bao.controlplane.io/consumer" == "fe-signalloom")] | length == 1'\'' -' _ "$bao_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-dashboard-egress")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.ports[]?.port == 8200)] | length == 0'\'' -' _ "$fe_policy"
  [ "$status" -eq 0 ]
}

@test "Runner assertions match both sides of their declared policies" {
  fe_policy="$slice_root/apps/fe-signalloom/base/networkpolicy.yaml"
  runner_policy="$slice_root/apps/supercred-demo-runner/base/networkpolicy.yaml"

  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-dashboard-egress")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.ports[]?.port == 8000 and .to[].podSelector.matchLabels."app.kubernetes.io/name" == "supercred-demo-runner")] | length == 1'\'' -' _ "$fe_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-supercred-demo-runner-ingress")'\'' "$1" | yq -e '\''[.spec.ingress[].from[] | select(.podSelector.matchLabels."app.kubernetes.io/name" == "dashboard-signalloom")] | length == 1'\'' -' _ "$runner_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-supercred-demo-runner-egress")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.ports[]?.port == 8000 and .to[].podSelector.matchLabels."app.kubernetes.io/name" == "fe-signalloom")] | length == 1'\'' -' _ "$runner_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-dashboard-to-api-ingress")'\'' "$1" | yq -e '\''[.spec.ingress[].from[] | select(.podSelector.matchLabels."app.kubernetes.io/name" == "supercred-demo-runner")] | length == 1'\'' -' _ "$fe_policy"
  [ "$status" -eq 0 ]
}

@test "Policy-engine and DNS assertions match source and destination boundaries" {
  infra_policy="$slice_root/infra/inf-signalloom/configs/base/networkpolicy.yaml"
  runner_policy="$slice_root/apps/supercred-demo-runner/base/networkpolicy.yaml"

  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-dependency-traffic")'\'' "$1" | yq -e '\''([.spec.ingress[].from[] | select((.podSelector | keys | length) == 0)] | length == 1) and ([.spec.egress[].to[] | select((.podSelector | keys | length) == 0)] | length == 1)'\'' -' _ "$infra_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-supercred-demo-runner-egress")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.ports[]?.port == 8081)] | length == 0'\'' -' _ "$runner_policy"
  [ "$status" -eq 0 ]
  run bash -c 'yq -N '\''select(.kind == "NetworkPolicy" and .metadata.name == "allow-supercred-demo-runner-egress")'\'' "$1" | yq -e '\''[.spec.egress[] | select(.to[].podSelector.matchLabels."k8s-app" == "kube-dns") | .ports[] | .protocol + ":" + (.port | tostring)] | sort | join(",") == "TCP:53,UDP:53"'\'' -' _ "$runner_policy"
  [ "$status" -eq 0 ]
}

@test "Structured catalogue is generated directly from canonical YAML" {
  catalogue="$BATS_TEST_TMPDIR/catalogue.json"
  run bash -c '"$1" --catalogue-json >"$2"' _ "$checker" "$catalogue"
  [ "$status" -eq 0 ]
  run yq -p=json -e '.schemaVersion == "signalloom.netassert.catalogue/v1" and .suiteId == "signalloom-network-policy" and (.assertions | length) == 26 and (.runtimePrerequisites | length) == 3' "$catalogue"
  [ "$status" -eq 0 ]
}

@test "Committed catalogue exactly matches canonical generator bytes" {
  generated="$BATS_TEST_TMPDIR/catalogue.json"
  "$checker" --catalogue-json >"$generated"
  run cmp "$generated" "$slice_root/apps/fake-integration-proxy/network-test-catalogue.json"
  [ "$status" -eq 0 ]
}

@test "SPIRE host-network enforcement limitation remains explicit" {
  run grep -F 'SPIRE agent uses hostNetwork; Kubernetes NetworkPolicy cannot prove its node-network enforcement.' "$canonical"
  [ "$status" -eq 0 ]
}
