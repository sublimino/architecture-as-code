#!/usr/bin/env bats
# swarm-infra.bats — static validation of agent swarm infrastructure manifests.
#
# These tests run without a cluster. They validate that the YAML and shell
# files exist, are syntactically correct, and contain the expected fields.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# ─── OpenBao glob role ───────────────────────────────────────────────────────

@test "openbao-agent-generic-role.yaml exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml" ]
}

@test "openbao-agent-generic-role has glob bound_claims for trust domain" {
  grep -q 'spiffe://signalloom.demo/ns/\*/sa/\*' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
}

@test "openbao-agent-generic-role sets token_ttl 30m" {
  grep -q 'token_ttl.*30m' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
}

@test "openbao-agent-generic-role uses audience openbao-supercredential" {
  grep -q 'openbao-supercredential' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
}

@test "openbao-agent-generic-role has templated policy with identity alias metadata" {
  grep -q 'identity.entity.aliases.auth_jwt.metadata' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
}

@test "openbao-agent-generic-role is in kustomization.yaml" {
  grep -q 'openbao-agent-generic-role.yaml' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/kustomization.yaml"
}

# ─── SPIRE agent swarm entries ───────────────────────────────────────────────

@test "spire-agent-swarm-entries.yaml exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml" ]
}

@test "spire-agent-swarm-entries has pod-label selector" {
  grep -q 'k8s:pod-label:signalloom.ai/agent:true' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml"
}

@test "spire-agent-swarm-entries is in kustomization.yaml" {
  grep -q 'spire-agent-swarm-entries.yaml' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/kustomization.yaml"
}

# ─── Knative manifests ──────────────────────────────────────────────────────

@test "knative serving manifest exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/knative/knative-serving.yaml" ]
}

@test "knative eventing manifest exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/knative/knative-eventing.yaml" ]
}

@test "knative broker manifest exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/knative/broker.yaml" ]
}

@test "knative github-source manifest exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/infra/knative/github-source.yaml" ]
}

@test "knative kustomization.yaml lists all resources" {
  local kust="${REPO_ROOT}/d2-signalloom/infra/knative/kustomization.yaml"
  grep -q 'knative-serving.yaml' "${kust}"
  grep -q 'knative-eventing.yaml' "${kust}"
  grep -q 'broker.yaml' "${kust}"
  grep -q 'github-source.yaml' "${kust}"
}

@test "knative broker targets fe-signalloom-agents namespace" {
  grep -q 'namespace: fe-signalloom-agents' \
    "${REPO_ROOT}/d2-signalloom/infra/knative/broker.yaml"
}

# ─── Agent swarm ServiceAccounts ─────────────────────────────────────────────

@test "all 10 agent ServiceAccounts are defined" {
  local rbac="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/rbac.yaml"
  local agents=(
    prompt-commit-summarizer
    triage-ci-worker
    zulip-chat-agent
    cpai-engineer
    hosted-daytona-coder
    swarm-governor
    prod-deploy-gate
    agent-cardvault
    nono-containment-probe
    # The stun sentinel's SA (stun-sentinel) is declared beside its DaemonSet,
    # not in this file; d2-signalloom/test/stun-sentinel-daemonset.bats pins it.
  )
  for sa in "${agents[@]}"; do
    grep -q "name: ${sa}" "${rbac}"
  done
}

@test "agent ServiceAccounts carry signalloom.ai/agent label" {
  local count
  count=$(grep -c 'signalloom.ai/agent: "true"' \
    "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/rbac.yaml")
  [ "${count}" -ge 10 ]
}

@test "agent namespace has signalloom.ai/managed label" {
  grep -q 'signalloom.ai/managed.*true' \
    "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/namespace.yaml"
}

# ─── eBPF sentinel RBAC ─────────────────────────────────────────────────────

# Both used to grep a file for a word. "reads nodes" then passed on the
# tombstone comment that records the node-reader grant's removal. They now ask
# the rendered manifests, which is what the cluster applies.

@test "stun sentinel Role grants patch on pods, which its pod-annotation write needs" {
  # The namespaced Role has one owner, next to the DaemonSet; see
  # d2-signalloom/test/stun-sentinel-daemonset.bats.
  run bash -c "kubectl kustomize '${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel' \
    | yq -r 'select(.kind == \"Role\" and .metadata.name == \"stun-sentinel\") | .rules[] | select(.resources[] == \"pods\") | .verbs[]'"
  [ "$status" -eq 0 ]
  grep -qx patch <<<"$output"
}

@test "stun sentinel holds no cluster-scoped grant (it never reads nodes)" {
  # No sentinel code calls the nodes API; the node-reader ClusterRole was
  # unused and is gone (ebpf-sentinel-rbac.yaml tombstone).
  local dir out=""
  for dir in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm" \
             "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel"; do
    out="${out}$(kubectl kustomize "$dir" | yq -r 'select(.kind == "ClusterRoleBinding") | select([.subjects[]? | .name | test("stun-sentinel")] | any) | .metadata.name')"
  done
  [ -z "$out" ] || { echo "cluster-scoped sentinel bindings: $out"; return 1; }
}

# ─── Auto-claim script ──────────────────────────────────────────────────────

@test "agent-auto-claim.sh is syntactically valid bash" {
  bash -n "${REPO_ROOT}/scripts/lib/agent-auto-claim.sh"
}

@test "agent-auto-claim.sh defines auto_claim_agent function" {
  grep -q 'auto_claim_agent()' \
    "${REPO_ROOT}/scripts/lib/agent-auto-claim.sh"
}

@test "agent-auto-claim.sh defines release_claim function" {
  grep -q 'release_claim()' \
    "${REPO_ROOT}/scripts/lib/agent-auto-claim.sh"
}

# ─── Dashboard TypeScript modules ────────────────────────────────────────────

@test "agentDiscovery.ts exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/data/agentDiscovery.ts" ]
}

@test "agentClaim.ts exists" {
  [ -f "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/api/agentClaim.ts" ]
}

@test "agentDiscovery.ts exports AGENT_LABELS constant" {
  grep -q 'export const AGENT_LABELS' \
    "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/data/agentDiscovery.ts"
}

@test "agentDiscovery.ts exports discoverAgents function" {
  grep -q 'export async function discoverAgents' \
    "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/data/agentDiscovery.ts"
}

@test "agentClaim.ts exports AgentClaimRequest type" {
  grep -q 'export interface AgentClaimRequest' \
    "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/api/agentClaim.ts"
}

@test "agentClaim.ts exports submitClaim function" {
  grep -q 'export async function submitClaim' \
    "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/api/agentClaim.ts"
}

# ─── Makefile targets ────────────────────────────────────────────────────────

@test "Makefile has swarm-infra-up target" {
  grep -q '^swarm-infra-up:' "${REPO_ROOT}/Makefile"
}

@test "Makefile has swarm-infra-down target" {
  grep -q '^swarm-infra-down:' "${REPO_ROOT}/Makefile"
}

@test "Makefile has swarm-openbao-role target" {
  grep -q '^swarm-openbao-role:' "${REPO_ROOT}/Makefile"
}
