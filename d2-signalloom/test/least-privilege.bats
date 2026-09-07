#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  # Single canonical Signal Loom tenant ResourceSet, owned by the fleet.
  canonical="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
}

@test "Signalloom tenants remain namespace-bound outside their exact SPIRE grant" {
  run grep -F 'name: cluster-admin' "$canonical"
  [ "$status" -ne 0 ]

  # Four, and only these four. The count alone would silently accept any new
  # cluster-scoped binding, which is the exact thing this test exists to catch,
  # so the names are pinned too: two flux-ns-patch bindings (one per cluster
  # slice), the SPIRE agent's kubelet grant, and supercred-demo-runner, whose
  # ClusterRole is bounded to namespaces get/create/patch and nodes get.
  run grep -c 'kind: ClusterRoleBinding' "$canonical"
  [ "$status" -eq 0 ]
  [ "$output" -eq 4 ]

  run grep -c 'name: supercred-demo-runner$' "$canonical"
  [ "$status" -eq 0 ]

  run grep -c 'name: signalloom-spire-agent-kubelet' "$canonical"
  [ "$status" -eq 0 ]

  run grep -c 'name: flux-ns-patch-<< inputs.tenant >>' "$canonical"
  [ "$status" -eq 0 ]
  [ "$output" -eq 6 ]

  run grep -F 'resources: ["nodes/proxy"]' "$canonical"
  [ "$status" -eq 0 ]

  run grep -c 'toolkit.fluxcd.io/role: tenant' "$canonical"
  [ "$status" -eq 0 ]
  # Was 2. Fleet-agents' RoleBinding for agent pod labels carries the tenant
  # label — it is a legitimate tenant-scoped grant, not a cluster-wide escape.
  [ "$output" -eq 3 ]

  run grep -c 'automountServiceAccountToken: false' "$canonical"
  [ "$status" -eq 0 ]
  # Two existing bootstrap identities plus two tokenless network fixtures.
  [ "$output" -eq 4 ]
}

@test "default-deny policies retain only the declared Signalloom paths" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: default-deny"* ]]
  [[ "$output" == *"name: allow-portal-dependencies"* ]]
  [[ "$output" == *"port: 5432"* ]]
  [[ "$output" == *"port: 6379"* ]]
  [[ "$output" == *"port: 9000"* ]]
  [[ "$output" == *"port: 8200"* ]]

  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-bao/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: allow-bao-spire-and-portal"* ]]

  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-signalloom/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: allow-dependency-traffic"* ]]
}

@test "netassert runner reaches only the Kubernetes API transport" {
  policy="$repo_root/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml"

  run yq eval-all '
    select(.metadata.name == "allow-netassert-runner-egress")
    | [
        .spec.podSelector.matchLabels."signalloom.ai/purpose",
        .spec.policyTypes[],
        .spec.egress[].ports[] | .protocol + ":" + (.port | tostring)
      ] | .[]
  ' "$policy"
  [ "$status" -eq 0 ]
  [ "$output" = $'network-test-run\nEgress\nTCP:443\nTCP:6443' ]
}

@test "netassert resolver accepts Kubernetes pretty and compact JSON" {
  resolver="$repo_root/d2-signalloom/netassert-runner/resolve-agent-pod.sh"
  fake_bin="$BATS_TEST_TMPDIR/resolver-bin"
  config="$BATS_TEST_TMPDIR/netassert.yaml"
  token="$BATS_TEST_TMPDIR/token"
  calls="$BATS_TEST_TMPDIR/curl.calls"
  mkdir -p "$fake_bin"
  printf 'fixture-token\n' >"$token"
  cat >"$config" <<'YAML'
- name: agent-to-cardvault
  src:
    k8sResource: {kind: pod, name: agent-patsy, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: cardvault, namespace: inf-signalloom}
YAML
  cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
printf '%s\n' "$url" >>"$CURL_CALLS"
case "$url" in
  */pods\?labelSelector=signalloom.ai%2Fagent%3Dtrue%2Csignalloom.ai%2Fframework%3Dcustom%2Cnetassert.signalloom.ai%2Ffixture%3Dgeneric-agent) cat "$POD_RESPONSE" ;;
  */deployments/cardvault) printf '%s\n' '{"metadata":{"name":"cardvault"},"status":{"availableReplicas":1}}' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$fake_bin/curl"

  for format in pretty compact; do
    response="$BATS_TEST_TMPDIR/$format.json"
    output_file="$BATS_TEST_TMPDIR/$format.yaml"
    if [ "$format" = pretty ]; then
      cat >"$response" <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "agent-pretty"},
      "status": {
        "phase": "Running",
        "conditions": [{"type": "Ready", "status": "True"}]
      }
    }
  ]
}
JSON
      expected=agent-pretty
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"agent-compact"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' >"$response"
      expected=agent-compact
    fi
    run env PATH="$fake_bin:$PATH" TOKEN_FILE="$token" CA_CERT="$BATS_TEST_TMPDIR/ca.crt" \
      KUBERNETES_API=https://kubernetes.invalid CONFIG_FILE="$config" OUTPUT_FILE="$output_file" \
      POD_RESPONSE="$response" CURL_CALLS="$calls" sh "$resolver"
    [ "$status" -eq 0 ]
    run yq -e ".[0].src.k8sResource.name == \"$expected\" and .[0].dst.k8sResource.name == \"cardvault\"" "$output_file"
    [ "$status" -eq 0 ]
  done
  run grep -F '/apis/apps/v1/namespaces/inf-signalloom/deployments/cardvault' "$calls"
  [ "$status" -eq 0 ]
}

@test "netassert runner patch rights remain namespace scoped" {
  fleet="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"

  run yq ea -r '
    select(.metadata.name == "signalloom-infra")
    | .spec.resources[]
    | select(.kind == "Role" and .metadata.name == "netassert-runner" and .metadata.namespace == "fe-signalloom-agents")
    | .rules[]
    | [.resources[], .verbs[]] | .[]
  ' "$fleet"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pods/ephemeralcontainers"* ]]
  [[ "$output" == *"patch"* ]]

  run yq ea -r '
    select(.metadata.name == "signalloom-infra")
    | .spec.resources[]
    | select(.kind == "Role" and .metadata.name == "netassert-runner")
    | [.rules[].resources[], .rules[].verbs[]] | .[]
  ' "$fleet"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pods/ephemeralcontainers"* ]]
  [[ "$output" == *"patch"* ]]

  run yq e -r '
    select(.kind == "ResourceSet")
    | .spec.resources[]
    | select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")
    | select(.metadata.name | test("netassert"))
    | .metadata.name
  ' "$fleet"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "positive and negative Bao proofs are distinct service-account outcomes" {
  proof="$repo_root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"
  runner="$repo_root/scripts/bao-spire-proof.sh"

  run grep -F 'serviceAccountName: fe-signalloom' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'serviceAccountName: fe-signalloom-negative' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'args: ["write", "--audience", "openbao"' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'args: ["expect-denied", "--audience", "openbao"' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'denied as expected' "$repo_root/d2-signalloom/proof-helper/main.go"
  [ "$status" -eq 0 ]
  run grep -F 'wait "job/$negative" --for=condition=complete' "$runner"
  [ "$status" -eq 0 ]
  run grep -F 'condition=failed' "$runner"
  [ "$status" -ne 0 ]
  run grep -F 'logs "job/$negative" -c jwt-svid' "$runner"
  [ "$status" -eq 0 ]
}
