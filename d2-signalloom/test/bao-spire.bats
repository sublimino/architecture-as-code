#!/usr/bin/env bats

setup() { root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"; }

@test "bounded Bao/SPIRE identity is exact and has a negative service account" {
  run "$root/d2-signalloom/test/validate-bao-spire.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"configuration validates"* ]]
}

@test "all Bao-dependent application proof objects carry the consumer label" {
  run yq -e 'select(.kind == "Job") | .metadata.labels["bao.controlplane.io/consumer"] == "fe-signalloom"' "$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"
  [ "$status" -eq 0 ]
}

@test "OpenBao bypasses the root su-exec transition without weakening its pod security context" {
  run kubectl kustomize "$root/d2-signalloom/infra/inf-bao/controllers/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"command:"* ]]
  [[ "$output" == *"- /bin/bao"* ]]
  [[ "$output" == *"runAsNonRoot: true"* ]]
  [[ "$output" == *"runAsUser: 100"* ]]
  [[ "$output" == *"runAsGroup: 1000"* ]]
  [[ "$output" == *"allowPrivilegeEscalation: false"* ]]
  [[ "$output" == *"- ALL"* ]]
}

@test "SPIRE ConfigMaps reconcile in the controller slice before its health check" {
  run kubectl kustomize "$root/d2-signalloom/infra/inf-bao/controllers/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: spire-server-config"* ]]
  [[ "$output" == *"name: spire-agent-config"* ]]

  run kubectl kustomize "$root/d2-signalloom/infra/inf-bao/configs/local"
  [ "$status" -eq 0 ]
  run yq -e 'select(.kind == "ConfigMap" and (.metadata.name == "spire-server-config" or .metadata.name == "spire-agent-config"))' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "SPIRE relies on its image entrypoint rather than duplicating its run command" {
  manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml"
  agent="$root/d2-signalloom/infra/inf-bao/configs/base/spire-agent.yaml"
  run grep -F 'args: ["-config", "/run/spire/config/server.conf"]' "$manifest"
  [ "$status" -eq 0 ]
  run grep -F 'args: ["-config", "/run/spire/config/agent.conf", "-expandEnv"]' "$agent"
  [ "$status" -eq 0 ]
  run grep -E 'args: \["spire-(server|agent)", "run"' "$manifest" "$agent"
  [ "$status" -ne 0 ]
}

@test "local SPIRE bootstrap has a disk key path and explicitly bounded insecure bootstrap" {
  config="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
  run grep -F 'keys_path = "/run/spire/data/keys.json"' "$config"
  [ "$status" -eq 0 ]
  run grep -F 'insecure_bootstrap = true' "$config"
  [ "$status" -eq 0 ]
  run grep -F 'join_token = "$${JOIN_TOKEN}"' "$config"
  [ "$status" -eq 0 ]
}
