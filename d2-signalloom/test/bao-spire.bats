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

@test "Bao proof uses direct OpenBao commands and shared token storage" {
  manifest="$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"

  run yq -r 'select(.kind == "Job" and .metadata.name == "bao-spire-positive-proof") | .spec.template.spec.initContainers[] | select(.name == "bao-login") | [.command | join(" "), .args | join(" "), (.env[] | select(.name == "HOME").value)] | @tsv' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = $'/bin/bao\tlogin -no-print -method=jwt -path=jwt role=signalloom-fe-signalloom jwt=@/work/jwt\t/work/home' ]

  run yq -r 'select(.kind == "Job" and .metadata.name == "bao-spire-positive-proof") | .spec.template.spec.containers[] | select(.name == "proof") | [.command | join(" "), .args | join(" "), (.env[] | select(.name == "HOME").value)] | @tsv' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = $'/bin/bao\tkv get kv/signalloom/fe-signalloom\t/work/home' ]
}

@test "Bao proof JWT-SVID commands use the executable shipped in their image" {
  manifest="$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"

  run yq -e '
    select(.kind == "Job")
    | .spec.template.spec.initContainers[]
    | select(.name == "jwt-svid")
    | ((.command | length) == 1
      and .command[0] == "/usr/local/bin/signalloom-spire-proof"
      and (.args[0] == "write" or .args[0] == "expect-denied"))
  ' "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"false"* ]]

  run grep -E '(/bin/)?(ba)?sh|[|]|sed|[$][(]|cat /work/jwt' "$manifest"
  [ "$status" -ne 0 ]
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

@test "SPIRE agent has only the local kubelet proxy permission it needs" {
  fleet="$root/d2-osramp-fleet/tenants/local/signalloom.yaml"
  run yq ea -e 'select(.kind == "ResourceSet" and .metadata.name == "signalloom-spire-rbac") | .spec.resources[] | select(.kind == "ClusterRole") | ((.rules[0].apiGroups[0] == "") and (.rules[0].resources[0] == "nodes/proxy") and (.rules[0].verbs[0] == "get"))' "$fleet"
  [ "$status" -eq 0 ]
  run yq ea -e 'select(.kind == "ResourceSet" and .metadata.name == "signalloom-spire-rbac") | .spec.resources[] | select(.kind == "ClusterRoleBinding") | ((.subjects[0].kind == "ServiceAccount") and (.subjects[0].name == "spire-agent") and (.subjects[0].namespace == "inf-bao") and (.roleRef.name == "signalloom-spire-agent-kubelet"))' "$fleet"
  [ "$status" -eq 0 ]
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
