#!/usr/bin/env bats
# test/kagent-credentials.bats — Agent identity and credential wiring.
#
# SCOPE. Identity (ServiceAccounts, SPIFFE-derivable names) and the *linkage*
# from a ModelConfig to the Secret it will read. Whether the Secret's contents
# are a usable credential is asserted in test/kagent-anti-stub.bats ("the model
# API key secret is not a demo placeholder") — deliberately kept there, because
# it is the assertion that fails on the shipped mock and this file must not be
# the place where that failure gets softened.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
  ALL_AGENTS="kagent-k8s-reader kagent-commit-summariser kagent-security-analyst kagent-network-auditor kagent-incident-responder kagent-compliance-checker kagent-finops-optimizer kagent-chaos-prober"
}

@test "kagent-creds: service accounts exist with signalloom.ai/agent label for all 8 agents" {
  for sa in $ALL_AGENTS; do
    run kubectl get sa "${sa}" -n "${NS}" -o jsonpath="{.metadata.labels.signalloom\\.ai/agent}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "kagent-creds: every Agent CR has a ServiceAccount of the same name" {
  # The dashboard derives the second half of a SPIFFE ID from the Agent CR's
  # name (see the long note in d2-signalloom/test/kagent-contract.bats). That
  # file enforces the invariant on disk; this enforces it against the cluster,
  # where a partially-applied overlay can break it without touching a manifest.
  agents="$(kubectl get agents -n "${NS}" -o json | jq -r '.items[].metadata.name')"
  [ -n "$agents" ] || {
    echo "no Agent CRs in ${NS} — nothing was inspected"
    return 1
  }
  missing=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    kubectl get sa "$a" -n "${NS}" >/dev/null 2>&1 || missing+="$a "
  done <<<"$agents"

  if [ -n "$missing" ]; then
    echo "Agent CRs with no ServiceAccount of the same name: $missing"
    echo "the governance UI would render a SPIFFE ID that SPIRE never issued"
  fi
  [ -z "$missing" ]
}

@test "kagent-creds: ModelConfig names an Anthropic model and an existing Secret" {
  # Was: provider == "Anthropic" and nothing else. A ModelConfig pointing at a
  # Secret that does not exist passes that check and fails at first use, which
  # is exactly the class of break this suite is supposed to catch early.
  run kubectl get modelconfig anthropic-claude -n "${NS}" -o json
  [ "$status" -eq 0 ]
  mc="$output"

  provider="$(printf '%s' "$mc" | jq -r '.spec.provider // "ABSENT"')"
  [ "$provider" = "Anthropic" ]

  model="$(printf '%s' "$mc" | jq -r '.spec.model // ""')"
  [ -n "$model" ] || {
    echo "ModelConfig anthropic-claude names no model"
    return 1
  }

  # The reference may sit at spec.apiKeySecret (where the upstream v1alpha2 CRD
  # defines it) or at spec.anthropic.apiKeySecret (where this repo's manifests
  # put it). Accept either, but require one.
  #
  # This distinction is not cosmetic. Under the real CRD, `anthropic` only
  # admits baseUrl/maxTokens/temperature/topK/topP — so an apiKeySecret nested
  # there is PRUNED by the API server on write. `kubectl apply` succeeds,
  # nothing warns, and spec.anthropic comes back as {}. The credential
  # reference disappears silently and the agent has no key at run time.
  secret_name="$(printf '%s' "$mc" | jq -r '.spec.apiKeySecret // .spec.anthropic.apiKeySecret // ""')"
  [ -n "$secret_name" ] || {
    echo "ModelConfig anthropic-claude references no API key Secret."
    echo "spec as stored by the API server:"
    printf '%s' "$mc" | jq -c '.spec' | sed 's/^/  /'
    echo "If the manifest sets spec.anthropic.apiKeySecret, it was pruned:"
    echo "the v1alpha2 CRD defines apiKeySecret and apiKeySecretKey at the TOP"
    echo "level of spec, and spec.anthropic accepts only baseUrl/maxTokens/"
    echo "temperature/topK/topP. A pruned field fails at run time, not at apply."
    return 1
  }

  # The Secret is created in the kagent namespace by the control-plane manifests
  # and in the agent namespace by the overlays; accept either, fail if neither.
  found_in=""
  for ns in "${NS}" kagent; do
    if kubectl get secret "$secret_name" -n "$ns" >/dev/null 2>&1; then
      found_in="$ns"
      break
    fi
  done
  [ -n "$found_in" ] || {
    echo "ModelConfig references Secret '$secret_name', which exists in neither ${NS} nor kagent"
    return 1
  }

  # Non-empty is the floor. Whether the value is a real key is asserted by
  # test/kagent-anti-stub.bats; duplicating a weaker version of that check here
  # would give two green ticks for one property and hide the strong one.
  keys="$(kubectl get secret "$secret_name" -n "$found_in" -o json | jq -r '.data | keys | length')"
  [ "${keys:-0}" -ge 1 ]
}

@test "kagent-creds: GitHub token secret exists and is wired to the summariser" {
  # Previously titled "mock GitHub token secret exists for summariser
  # scaffolding" and asserting only that a Secret with that name existed —
  # i.e. asserting the presence of a placeholder, and passing forever whether
  # or not anything consumed it. Assert the linkage instead, which is the part
  # that has to survive the credential work.
  run kubectl get secret kagent-github-key -n "${NS}" -o json
  [ "$status" -eq 0 ]
  keys="$(printf '%s' "$output" | jq -r '.data | keys | length')"
  [ "${keys:-0}" -ge 1 ] || {
    echo "Secret kagent-github-key carries no data"
    return 1
  }

  # The summariser must be the agent that binds the github MCPServer, or this
  # Secret is unreferenced scaffolding rather than a credential in use.
  servers="$(kubectl get agent kagent-commit-summariser -n "${NS}" -o json |
    jq -r '[ .spec.declarative.tools[]?.mcpServer.name ] | join(",")')"
  [[ "$servers" == *"github-tool"* ]] || {
    echo "kagent-commit-summariser binds '$servers' — no github-tool, so kagent-github-key is unused"
    return 1
  }
}
